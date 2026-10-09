-- =====================================================================
-- Fixes de cupo real y consistencia de estados (aplicado 2026-10-06)
-- 1) cupoDisponible/diponible incluyen porciones TP_SOLICITUD_UNIDADES
-- 2) asignar/unir/asignar-multiples validan contra cupo DISPONIBLE por fecha
-- 3) anular marca porciones ANULADO
-- 4) listarTraslados excluye solicitudes anuladas
-- 5) marcarRealizado propaga a porciones
-- =====================================================================

-- 1) LISTAR UNIDADES: cupoDisponible con porciones incluidas
CREATE OR ALTER PROCEDURE TRANSPORTE_listarUnidades @json NVARCHAR(MAX)
AS BEGIN
    DECLARE @fecha DATE = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE), CAST(GETDATE() AS DATE));

    SELECT u.idUnidad, u.placa, u.capacidad,
           CASE WHEN EXISTS (SELECT 1 FROM TP_SOLICITUDES s
                             WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                               AND s.estado IN ('ASIGNADO', 'EN_RUTA'))
                OR EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES su
                           JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                           WHERE su.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                             AND su.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO')
                THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS disponible,
           u.capacidad
             - COALESCE((SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
                         WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                           AND s.estado IN ('ASIGNADO', 'EN_RUTA')), 0)
             - COALESCE((SELECT SUM(su.cantidadAsignada) FROM TP_SOLICITUD_UNIDADES su
                         JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                         WHERE su.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                           AND su.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO'), 0)
               AS cupoDisponible
    FROM TP_UNIDADES u WHERE u.activa = 1 ORDER BY u.placa FOR JSON PATH;
END
GO

-- 2a) ASIGNAR UNIDAD: valida cupo disponible por fecha (no solo capacidad) y estado PENDIENTE
CREATE OR ALTER PROCEDURE TRANSPORTE_asignarUnidad
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @cantidad INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @id);
    DECLARE @fecha DATE = (SELECT fechaProgramada FROM TP_SOLICITUDES WHERE idSolicitud = @id);

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END
    IF @cantidad IS NULL BEGIN RAISERROR('Solicitud inexistente', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND estado = 'PENDIENTE')
    BEGIN RAISERROR('La solicitud no esta pendiente de asignacion', 16, 1); RETURN; END

    -- Cupo libre real: capacidad - asignaciones directas - porciones de la misma fecha
    DECLARE @ocupado INT =
        COALESCE((SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
                  WHERE s.placa = @placa AND s.fechaProgramada = @fecha
                    AND s.estado IN ('ASIGNADO', 'EN_RUTA') AND s.idSolicitud <> @id), 0)
      + COALESCE((SELECT SUM(su.cantidadAsignada) FROM TP_SOLICITUD_UNIDADES su
                  JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                  WHERE su.idUnidad = @idUnidad AND s2.fechaProgramada = @fecha
                    AND su.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO'
                    AND s2.idSolicitud <> @id), 0);

    IF @cantidad > @capacidad - @ocupado
    BEGIN RAISERROR('La unidad no tiene cupo suficiente para esa fecha', 16, 1); RETURN; END

    UPDATE TP_SOLICITUDES
    SET placa = @placa, estado = 'ASIGNADO'
    WHERE idSolicitud = @id;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Solicitud #', @id, ' asignada a la unidad ', @placa), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud asignada', CONCAT('Su solicitud #', @id, ' fue asignada a la unidad ', @placa), 'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @id AND u.activo = 1;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @id, 'ASIGNAR_UNIDAD', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- 2b) UNIR SOLICITUDES: misma fecha, solo pendientes, cupo disponible real
CREATE OR ALTER PROCEDURE TRANSPORTE_unirSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idTraslado INT;
    DECLARE @ruta NVARCHAR(1000);
    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @totalPersonas INT = (
        SELECT COALESCE(SUM(s.cantidad), 0)
        FROM TP_SOLICITUDES s
        JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT)
    );

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUDES s
               JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT)
               WHERE s.estado <> 'PENDIENTE' OR s.idTraslado IS NOT NULL)
    BEGIN RAISERROR('Solo se pueden unir solicitudes pendientes sin traslado', 16, 1); RETURN; END

    IF (SELECT COUNT(DISTINCT s.fechaProgramada)
        FROM TP_SOLICITUDES s
        JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT)) > 1
    BEGIN RAISERROR('Solo se pueden unir solicitudes de la misma fecha', 16, 1); RETURN; END

    DECLARE @fecha DATE = (
        SELECT TOP 1 s.fechaProgramada
        FROM TP_SOLICITUDES s
        JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT));

    DECLARE @ocupado INT =
        COALESCE((SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
                  WHERE s.placa = @placa AND s.fechaProgramada = @fecha
                    AND s.estado IN ('ASIGNADO', 'EN_RUTA')), 0)
      + COALESCE((SELECT SUM(su.cantidadAsignada) FROM TP_SOLICITUD_UNIDADES su
                  JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                  WHERE su.idUnidad = @idUnidad AND s2.fechaProgramada = @fecha
                    AND su.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO'), 0);

    IF @totalPersonas + @ocupado > @capacidad
    BEGIN RAISERROR('Las solicitudes superan el cupo disponible de la unidad', 16, 1); RETURN; END

    -- Tabla temporal con los puntos ordenados (compatible SQL Server 2016)
    DECLARE @Puntos TABLE (
        orden INT IDENTITY(1,1),
        punto NVARCHAR(150),
        tipo INT  -- 0 = partida, 1 = llegada final
    );

    INSERT INTO @Puntos (punto, tipo)
    SELECT s.puntoPartida, 0
    FROM TP_SOLICITUDES s
    JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT)
    ORDER BY j.[key];

    INSERT INTO @Puntos (punto, tipo)
    SELECT TOP 1 s.puntoLlegada, 1
    FROM TP_SOLICITUDES s
    JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT)
    ORDER BY j.[key] DESC;

    SELECT @ruta = STUFF((
        SELECT ' > ' + punto
        FROM @Puntos
        ORDER BY orden
        FOR XML PATH(''), TYPE
    ).value('.', 'NVARCHAR(MAX)'), 1, 3, '');

    INSERT INTO TP_TRASLADOS (placa, ruta) VALUES (@placa, @ruta);
    SET @idTraslado = SCOPE_IDENTITY();

    UPDATE s
    SET s.idTraslado = @idTraslado, s.placa = @placa, s.estado = 'ASIGNADO'
    FROM TP_SOLICITUDES s
    JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT);

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Traslado T-', @idTraslado, ' asignado a la unidad ', @placa), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud asignada', CONCAT('Su solicitud #', s.idSolicitud, N' se uni al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idTraslado = @idTraslado AND u.activo = 1;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('TRASLADO', @idTraslado, 'UNIR_SOLICITUDES', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT t.idTraslado, t.placa, t.ruta, t.estado
    FROM TP_TRASLADOS t WHERE t.idTraslado = @idTraslado
    FOR JSON PATH;
END
GO

-- 2c) ASIGNAR MULTIPLES: cupo disponible real por unidad y fecha; permite redistribuir
CREATE OR ALTER PROCEDURE TRANSPORTE_asignarMultiplesUnidades
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @requerido INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud);
    DECLARE @fecha DATE = (SELECT fechaProgramada FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud);
    DECLARE @asignado INT;

    SELECT @asignado = SUM(TRY_CAST(JSON_VALUE(value, '$.cantidad') AS INT)) FROM OPENJSON(@json, '$.unidades');

    IF @requerido IS NULL OR @asignado <> @requerido
    BEGIN RAISERROR(N'La distribucion debe cubrir exactamente la cantidad solicitada', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud AND estado IN ('EN_RUTA', 'REALIZADO', 'ANULADO'))
    BEGIN RAISERROR('La solicitud ya esta en curso, realizada o anulada', 16, 1); RETURN; END

    -- Cada unidad debe existir y tener cupo libre suficiente en esa fecha
    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@json, '$.unidades') j
        LEFT JOIN TP_UNIDADES u ON u.placa = JSON_VALUE(j.value, '$.placa') AND u.activa = 1
        WHERE u.idUnidad IS NULL
           OR TRY_CAST(JSON_VALUE(j.value, '$.cantidad') AS INT) >
              u.capacidad
              - COALESCE((SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
                          WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                            AND s.estado IN ('ASIGNADO', 'EN_RUTA') AND s.idSolicitud <> @idSolicitud), 0)
              - COALESCE((SELECT SUM(su2.cantidadAsignada) FROM TP_SOLICITUD_UNIDADES su2
                          JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su2.idSolicitud
                          WHERE su2.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                            AND su2.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO'
                            AND s2.idSolicitud <> @idSolicitud), 0)
    )
    BEGIN RAISERROR('Una unidad no existe o no tiene cupo suficiente para esa fecha', 16, 1); RETURN; END

    DELETE FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @idSolicitud;

    INSERT INTO TP_SOLICITUD_UNIDADES(idSolicitud, idUnidad, cantidadAsignada)
    SELECT @idSolicitud, u.idUnidad, TRY_CAST(JSON_VALUE(j.value, '$.cantidad') AS INT)
    FROM OPENJSON(@json, '$.unidades') j JOIN TP_UNIDADES u ON u.placa = JSON_VALUE(j.value, '$.placa');

    UPDATE TP_SOLICITUDES
    SET placa = CASE WHEN (SELECT COUNT(*) FROM OPENJSON(@json, '$.unidades')) = 1
                     THEN JSON_VALUE(@json, '$.unidades[0].placa') ELSE 'MULTIPLE' END,
        estado = 'ASIGNADO'
    WHERE idSolicitud = @idSolicitud;

    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT usr.idUsuario,'Nuevo servicio asignado',CONCAT('Solicitud #',@idSolicitud,' asignada a ',u.placa),'ASIGNACION'
    FROM TP_SOLICITUD_UNIDADES su JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad JOIN TP_USUARIOS usr ON usr.placa=u.placa AND usr.activo=1
    WHERE su.idSolicitud=@idSolicitud;

    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT usr.idUsuario,'Solicitud asignada',CONCAT('Su solicitud #',@idSolicitud,' fue asignada a ',u.placa),'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS usr ON usr.usuario=s.usuarioRegistra AND usr.activo=1
    JOIN TP_SOLICITUD_UNIDADES su ON su.idSolicitud=s.idSolicitud JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad
    WHERE s.idSolicitud=@idSolicitud;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'ASIGNAR_MULTIPLES_UNIDADES', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT su.idSolicitudUnidad, su.idSolicitud, u.idUnidad, u.placa, su.cantidadAsignada, su.estado
    FROM TP_SOLICITUD_UNIDADES su JOIN TP_UNIDADES u ON u.idUnidad = su.idUnidad
    WHERE su.idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

-- 3) ELIMINAR (anular): marca tambien las porciones como ANULADO
CREATE OR ALTER PROCEDURE TRANSPORTE_eliminarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);

    UPDATE TP_SOLICITUDES SET estado = 'ANULADO' WHERE idSolicitud = @id;
    UPDATE TP_SOLICITUD_UNIDADES SET estado = 'ANULADO' WHERE idSolicitud = @id;

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES('SOLICITUD',@id,'ANULAR',JSON_VALUE(@json,'$.usuario'),@json);

    SELECT @id AS idSolicitud, 'ANULADO' AS estado FOR JSON PATH;
END
GO

-- 4) LISTAR TRASLADOS: excluir solicitudes anuladas del detalle
CREATE OR ALTER PROCEDURE TRANSPORTE_listarTraslados
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);

    SELECT t.idTraslado, t.placa, t.ruta, t.estado, t.fechaCreacion,
           JSON_QUERY((SELECT s.idSolicitud, s.nombre, s.horaProgramada, s.puntoPartida,
                   s.puntoLlegada, s.cantidad, s.motivo, s.realizado, s.estado, s.esEmergencia
            FROM TP_SOLICITUDES s WHERE s.idTraslado = t.idTraslado AND s.estado <> 'ANULADO'
            FOR JSON PATH)) AS solicitudes,
           JSON_QUERY((SELECT p.idParada, p.idPunto, p.punto, p.orden, p.cantidadSube, p.cantidadBaja
            FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = t.idTraslado ORDER BY p.orden
            FOR JSON PATH)) AS paradas
    FROM TP_TRASLADOS t
    WHERE t.estado <> 'ANULADO'
      AND (@fecha IS NULL OR CAST(t.fechaCreacion AS DATE) = @fecha)
    ORDER BY t.fechaCreacion DESC
    FOR JSON PATH;
END
GO

-- 5) MARCAR REALIZADO: propaga a las porciones de la solicitud
CREATE OR ALTER PROCEDURE TRANSPORTE_marcarRealizado
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @realizado BIT = TRY_CAST(JSON_VALUE(@json, '$.realizado') AS BIT);

    UPDATE TP_SOLICITUD_UNIDADES
    SET estado = CASE WHEN @realizado = 1 THEN 'REALIZADO' ELSE 'ASIGNADO' END
    WHERE idSolicitud = @id;

    UPDATE TP_SOLICITUDES
    SET realizado = @realizado,
        estado = CASE WHEN @realizado = 1 THEN 'REALIZADO' ELSE 'ASIGNADO' END
    WHERE idSolicitud = @id;

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO
