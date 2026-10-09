-- =====================================================================
-- Validaciones finales del flujo (aplicado 2026-10-06)
-- 1) asignarMultiplesUnidades: rechaza placa duplicada y valida
--    la SUMA por unidad contra el cupo libre
-- 2) unirSolicitudes: ids unicos (deduplica)
-- 3) separarSolicitud: solo solicitudes ASIGNADO (no en ruta/realizadas)
-- 4) cambiarEstado: no permite PENDIENTE (usar desasignar) ni tocar anuladas
-- 5) reporteIndicadores: unidades y conductores incluyen porciones
-- =====================================================================

-- 1) Multiples unidades: sin duplicados y suma por placa <= cupo libre
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

    -- Una placa no puede repetirse en la distribucion
    IF EXISTS (SELECT 1 FROM OPENJSON(@json, '$.unidades') j
               GROUP BY JSON_VALUE(j.value, '$.placa') HAVING COUNT(*) > 1)
    BEGIN RAISERROR('No se puede repetir la misma unidad en la distribucion', 16, 1); RETURN; END

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

-- 2) Unir: deduplica ids (una tabla con ids unicos para todo el flujo)
CREATE OR ALTER PROCEDURE TRANSPORTE_unirSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idTraslado INT;
    DECLARE @ruta NVARCHAR(1000);
    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);

    -- Ids unicos (orden de llegada conservado por key)
    DECLARE @Ids TABLE (idSolicitud INT, orden INT);
    INSERT INTO @Ids
    SELECT TRY_CAST(j.value AS INT), MIN(TRY_CAST(j.[key] AS INT))
    FROM OPENJSON(@json, '$.ids') j
    GROUP BY TRY_CAST(j.value AS INT);

    DECLARE @totalPersonas INT = (
        SELECT COALESCE(SUM(s.cantidad), 0) FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud);

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud
               WHERE s.estado <> 'PENDIENTE' OR s.idTraslado IS NOT NULL)
    BEGIN RAISERROR('Solo se pueden unir solicitudes pendientes sin traslado', 16, 1); RETURN; END

    IF (SELECT COUNT(DISTINCT s.fechaProgramada)
        FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud) > 1
    BEGIN RAISERROR('Solo se pueden unir solicitudes de la misma fecha', 16, 1); RETURN; END

    DECLARE @fecha DATE = (
        SELECT TOP 1 s.fechaProgramada FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud);

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

    -- Tabla temporal con los puntos ordenados
    DECLARE @Puntos TABLE (
        orden INT IDENTITY(1,1),
        punto NVARCHAR(150),
        tipo INT  -- 0 = partida, 1 = llegada final
    );

    INSERT INTO @Puntos (punto, tipo)
    SELECT s.puntoPartida, 0
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud
    ORDER BY i.orden;

    INSERT INTO @Puntos (punto, tipo)
    SELECT TOP 1 s.puntoLlegada, 1
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud
    ORDER BY i.orden DESC;

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
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Traslado T-', @idTraslado, ' asignado a la unidad ', @placa), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud asignada', CONCAT('Su solicitud #', s.idSolicitud, ' se unio al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idTraslado = @idTraslado AND u.activo = 1;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('TRASLADO', @idTraslado, 'UNIR_SOLICITUDES', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT t.idTraslado, t.placa, t.ruta, t.estado
    FROM TP_TRASLADOS t WHERE t.idTraslado = @idTraslado
    FOR JSON PATH;
END
GO

-- 3) Separar: solo solicitudes ASIGNADO dentro de un traslado
CREATE OR ALTER PROCEDURE TRANSPORTE_separarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idTraslado INT = (SELECT idTraslado FROM TP_SOLICITUDES WHERE idSolicitud = @id);

    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND idTraslado IS NOT NULL AND estado = 'ASIGNADO')
    BEGIN RAISERROR('Solo se pueden separar solicitudes asignadas a un traslado que aun no inician', 16, 1); RETURN; END

    UPDATE TP_SOLICITUDES
    SET idTraslado = NULL, placa = NULL, estado = 'PENDIENTE'
    WHERE idSolicitud = @id;

    IF @idTraslado IS NOT NULL AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idTraslado = @idTraslado)
        UPDATE TP_TRASLADOS SET estado = 'ANULADO' WHERE idTraslado = @idTraslado;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud separada', CONCAT('Su solicitud #', @id, ' fue separada del traslado y volvio a Pendiente'), 'ESTADO'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @id AND u.activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @id, 'SEPARAR', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- 4) Cambiar estado: PENDIENTE no es valido aqui (usar desasignar); no toca anuladas
CREATE OR ALTER PROCEDURE TRANSPORTE_cambiarEstado
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idSolicitudUnidad INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitudUnidad') AS INT);
    DECLARE @estado NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.estado'));

    IF @estado NOT IN ('ASIGNADO', 'EN_RUTA', 'REALIZADO')
    BEGIN RAISERROR(N'Estado de solicitud invalido', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND estado <> 'ANULADO')
    BEGIN RAISERROR('La solicitud no existe o esta anulada', 16, 1); RETURN; END

    IF @idSolicitudUnidad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitudUnidad = @idSolicitudUnidad AND idSolicitud = @id AND estado <> 'ANULADO')
    BEGIN RAISERROR('La porcion de unidad no existe o esta anulada', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND placa IS NOT NULL)
    BEGIN RAISERROR('La solicitud debe tener una unidad asignada', 16, 1); RETURN; END

    IF @idSolicitudUnidad IS NOT NULL
    BEGIN
        UPDATE TP_SOLICITUD_UNIDADES SET estado = @estado WHERE idSolicitudUnidad = @idSolicitudUnidad AND idSolicitud = @id;
        UPDATE TP_SOLICITUDES
        SET estado = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO' AND estado <> 'ANULADO') THEN 'REALIZADO'
                          WHEN EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado = 'EN_RUTA') THEN 'EN_RUTA' ELSE 'ASIGNADO' END,
            realizado = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO' AND estado <> 'ANULADO') THEN 1 ELSE 0 END,
            fechaInicio = CASE WHEN @estado = 'EN_RUTA' AND fechaInicio IS NULL THEN GETDATE() ELSE fechaInicio END,
            fechaFin = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO' AND estado <> 'ANULADO') THEN GETDATE() ELSE fechaFin END
        WHERE idSolicitud = @id;
    END
    ELSE
    BEGIN
        UPDATE TP_SOLICITUDES
        SET estado = @estado,
            realizado = CASE WHEN @estado = 'REALIZADO' THEN 1 ELSE 0 END,
            fechaInicio = CASE WHEN @estado = 'EN_RUTA' AND fechaInicio IS NULL THEN GETDATE() ELSE fechaInicio END,
            fechaFin = CASE WHEN @estado = 'REALIZADO' THEN GETDATE() ELSE NULL END
        WHERE idSolicitud = @id;
    END
    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES('SOLICITUD',@id,CONCAT('ESTADO_',@estado),JSON_VALUE(@json,'$.usuario'),@json);
    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT u.idUsuario, 'Estado de movilidad actualizado', CONCAT('La solicitud #',@id,' cambio a ',@estado), 'ESTADO'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario=s.usuarioRegistra WHERE s.idSolicitud=@id AND u.activo=1;
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- 5) Indicadores: unidades y conductores incluyen porciones de MULTIPLE
CREATE OR ALTER PROCEDURE TRANSPORTE_reporteIndicadores
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @desde DATE = TRY_CAST(JSON_VALUE(@json, '$.desde') AS DATE);
    DECLARE @hasta DATE = TRY_CAST(JSON_VALUE(@json, '$.hasta') AS DATE);
    SELECT
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalSolicitudes,
      (SELECT COALESCE(SUM(cantidad),0) FROM TP_SOLICITUDES WHERE estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalPersonas,
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE estado = 'REALIZADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalRealizados,
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE prioridad = 'EMERGENCIA' AND estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalEmergencias,
      (SELECT COALESCE(AVG(CAST(DATEDIFF(MINUTE,fechaInicio,fechaFin) AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND fechaFin IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) tiempoPromedioMinutos,
      (SELECT COALESCE(AVG(CAST(CASE WHEN DATEDIFF(MINUTE,fechaRegistro,fechaInicio)<0 THEN 0 ELSE DATEDIFF(MINUTE,fechaRegistro,fechaInicio) END AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) esperaPromedioMinutos,
      (SELECT COALESCE(100.0*SUM(CASE WHEN ABS(DATEDIFF(MINUTE,DATEADD(MINUTE,DATEDIFF(MINUTE,0,TRY_CAST(horaProgramada AS TIME)),CAST(fechaProgramada AS DATETIME)),fechaInicio))<=10 THEN 1 ELSE 0 END)/NULLIF(COUNT(*),0),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) puntualidadPorcentaje,
      JSON_QUERY((SELECT placa, COUNT(*) viajes, SUM(personas) personas,
                         CAST(100.0 * SUM(personas) / NULLIF(COUNT(*) * MAX(capacidad), 0) AS DECIMAL(6,2)) ocupacionPorcentaje
                  FROM (
                      SELECT s.placa, s.cantidad AS personas, u.capacidad
                      FROM TP_SOLICITUDES s JOIN TP_UNIDADES u ON u.placa = s.placa
                      WHERE s.estado <> 'ANULADO' AND s.placa IS NOT NULL AND s.placa <> 'MULTIPLE'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                      UNION ALL
                      SELECT u.placa, su.cantidadAsignada, u.capacidad
                      FROM TP_SOLICITUD_UNIDADES su
                      JOIN TP_UNIDADES u ON u.idUnidad = su.idUnidad
                      JOIN TP_SOLICITUDES s ON s.idSolicitud = su.idSolicitud
                      WHERE su.estado <> 'ANULADO' AND s.estado <> 'ANULADO'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  ) x GROUP BY placa FOR JSON PATH)) unidades,
      JSON_QUERY((SELECT COALESCE(a.nombre, s.area) AS area, COUNT(*) solicitudes, SUM(s.cantidad) personas
                  FROM TP_SOLICITUDES s LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
                  WHERE s.estado <> 'ANULADO' AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  GROUP BY COALESCE(a.nombre, s.area) FOR JSON PATH)) areas,
      JSON_QUERY((SELECT u.nombre conductor, u.placa, COUNT(x.idSolicitud) servicios, COALESCE(SUM(x.personas),0) personas
                  FROM TP_USUARIOS u
                  LEFT JOIN (
                      SELECT s.placa, s.idSolicitud, s.cantidad AS personas
                      FROM TP_SOLICITUDES s
                      WHERE s.estado = 'REALIZADO' AND s.placa IS NOT NULL AND s.placa <> 'MULTIPLE'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                      UNION ALL
                      SELECT u2.placa, s.idSolicitud, su.cantidadAsignada
                      FROM TP_SOLICITUD_UNIDADES su
                      JOIN TP_UNIDADES u2 ON u2.idUnidad = su.idUnidad
                      JOIN TP_SOLICITUDES s ON s.idSolicitud = su.idSolicitud
                      WHERE su.estado = 'REALIZADO'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  ) x ON x.placa = u.placa
                  WHERE u.idrol = 'CHTRANS' AND u.activo = 1
                  GROUP BY u.nombre, u.placa FOR JSON PATH)) conductores
    FOR JSON PATH;
END
GO
