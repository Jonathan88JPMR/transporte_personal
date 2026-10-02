-- ============================================
-- TRANSPORTE DE PERSONAL - STORED PROCEDURES
-- Convención: reciben @json NVARCHAR(MAX), devuelven FOR JSON PATH
-- ============================================

-- LOGIN (parámetros sueltos, lo llama el controller directo)
CREATE OR ALTER PROCEDURE TRANSPORTE_login
    @usuario   NVARCHAR(50),
    @claveHash NVARCHAR(200)
AS
BEGIN
    SELECT u.idUsuario, u.usuario, u.nombre, u.idrol,
           CASE u.idrol
               WHEN 'SPTRANS' THEN 'SUPERVISOR'
               WHEN 'COTRANS' THEN 'COORDINADOR'
               WHEN 'CHTRANS' THEN 'CONDUCTOR'
               WHEN 'ADTRANS' THEN 'ADMINISTRADOR'
               ELSE u.idrol
           END AS rol,
           u.placa, u.area, u.claveHash
    FROM TP_USUARIOS u
    WHERE u.usuario = @usuario AND u.activo = 1;
END
GO

-- LISTAR SOLICITUDES  @json: { "fecha": "2026-09-25" (opcional), "estado": "PENDIENTE" (opcional) }
CREATE OR ALTER PROCEDURE TRANSPORTE_listarSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha  DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);
    DECLARE @estado NVARCHAR(20) = JSON_VALUE(@json, '$.estado');

    SELECT s.idSolicitud, s.idTraslado, s.nombre, s.area, s.fechaProgramada, s.horaProgramada,
           s.puntoPartida, s.puntoLlegada, s.cantidad, s.motivo, s.observacion, s.esEmergencia, s.placa,
           s.realizado, s.estado, s.usuarioRegistra, s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    WHERE (@fecha  IS NULL OR s.fechaProgramada = @fecha)
      AND (@estado IS NULL OR s.estado = @estado)
    -- RN-004: primero en llegar, primero en ser atendido (emergencias siempre al tope)
    ORDER BY s.esEmergencia DESC, s.fechaRegistro, s.idSolicitud
    FOR JSON PATH;
END
GO

-- GUARDAR SOLICITUD (insert/update)  @json: campos de la solicitud
CREATE OR ALTER PROCEDURE TRANSPORTE_guardarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);

    IF @idSolicitud IS NULL OR @idSolicitud = 0
    BEGIN
        INSERT INTO TP_SOLICITUDES (nombre, area, fechaProgramada, horaProgramada, puntoPartida, puntoLlegada,
                                    cantidad, motivo, observacion, esEmergencia, usuarioRegistra)
        SELECT JSON_VALUE(@json, '$.nombre'), JSON_VALUE(@json, '$.area'),
               COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fechaProgramada') AS DATE), CAST(GETDATE() AS DATE)),
               JSON_VALUE(@json, '$.horaProgramada'), JSON_VALUE(@json, '$.puntoPartida'),
               JSON_VALUE(@json, '$.puntoLlegada'), TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT),
               JSON_VALUE(@json, '$.motivo'), JSON_VALUE(@json, '$.observacion'),
               COALESCE(TRY_CAST(JSON_VALUE(@json, '$.esEmergencia') AS BIT), 0), JSON_VALUE(@json, '$.usuarioRegistra');
        SET @idSolicitud = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE TP_SOLICITUDES
        SET fechaProgramada = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fechaProgramada') AS DATE), fechaProgramada),
            horaProgramada = JSON_VALUE(@json, '$.horaProgramada'),
            puntoPartida   = JSON_VALUE(@json, '$.puntoPartida'),
            puntoLlegada   = JSON_VALUE(@json, '$.puntoLlegada'),
            cantidad       = TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT),
            motivo         = JSON_VALUE(@json, '$.motivo'),
            observacion    = JSON_VALUE(@json, '$.observacion'),
            esEmergencia   = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.esEmergencia') AS BIT), esEmergencia)
        WHERE idSolicitud = @idSolicitud;
    END

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('SOLICITUD',@idSolicitud,CASE WHEN JSON_VALUE(@json,'$.idSolicitud') IS NULL THEN 'CREAR' ELSE 'EDITAR' END,JSON_VALUE(@json,'$.usuarioRegistra'),@json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

-- ELIMINAR (anular)  @json: { "idSolicitud": 1 }
CREATE OR ALTER PROCEDURE TRANSPORTE_eliminarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    UPDATE TP_SOLICITUDES SET estado = 'ANULADO' WHERE idSolicitud = @id;
    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES('SOLICITUD',@id,'ANULAR',JSON_VALUE(@json,'$.usuario'),@json);
    SELECT @id AS idSolicitud, 'ANULADO' AS estado FOR JSON PATH;
END
GO

-- MARCAR REALIZADO  @json: { "idSolicitud": 1, "realizado": 1 }
CREATE OR ALTER PROCEDURE TRANSPORTE_marcarRealizado
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @realizado BIT = TRY_CAST(JSON_VALUE(@json, '$.realizado') AS BIT);

    UPDATE TP_SOLICITUDES
    SET realizado = @realizado,
        estado = CASE WHEN @realizado = 1 THEN 'REALIZADO' ELSE 'ASIGNADO' END
    WHERE idSolicitud = @id;

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- CAMBIAR ESTADO  @json: { "idSolicitud": 1, "estado": "EN_RUTA" }
CREATE OR ALTER PROCEDURE TRANSPORTE_cambiarEstado
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idSolicitudUnidad INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitudUnidad') AS INT);
    DECLARE @estado NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.estado'));

    IF @estado NOT IN ('PENDIENTE', 'ASIGNADO', 'EN_RUTA', 'REALIZADO')
    BEGIN RAISERROR(N'Estado de solicitud inválido', 16, 1); RETURN; END

    IF @estado IN ('ASIGNADO', 'EN_RUTA', 'REALIZADO')
       AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND placa IS NOT NULL)
    BEGIN RAISERROR('La solicitud debe tener una unidad asignada', 16, 1); RETURN; END

    IF @idSolicitudUnidad IS NOT NULL
    BEGIN
        UPDATE TP_SOLICITUD_UNIDADES SET estado = @estado WHERE idSolicitudUnidad = @idSolicitudUnidad AND idSolicitud = @id;
        UPDATE TP_SOLICITUDES
        SET estado = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO') THEN 'REALIZADO'
                          WHEN EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado = 'EN_RUTA') THEN 'EN_RUTA' ELSE 'ASIGNADO' END,
            realizado = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO') THEN 1 ELSE 0 END,
            fechaInicio = CASE WHEN @estado = 'EN_RUTA' AND fechaInicio IS NULL THEN GETDATE() ELSE fechaInicio END,
            fechaFin = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO') THEN GETDATE() ELSE fechaFin END
        WHERE idSolicitud = @id;
    END
    ELSE
    BEGIN
        UPDATE TP_SOLICITUDES
        SET estado = @estado,
            realizado = CASE WHEN @estado = 'REALIZADO' THEN 1 ELSE 0 END,
            fechaInicio = CASE WHEN @estado = 'EN_RUTA' AND fechaInicio IS NULL THEN GETDATE() ELSE fechaInicio END,
            fechaFin = CASE WHEN @estado = 'REALIZADO' THEN GETDATE() ELSE NULL END
        WHERE idSolicitud = @id AND estado <> 'ANULADO';
    END
    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES('SOLICITUD',@id,CONCAT('ESTADO_',@estado),JSON_VALUE(@json,'$.usuario'),@json);
    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT u.idUsuario, 'Estado de movilidad actualizado', CONCAT('La solicitud #',@id,N' cambió a ',@estado), 'ESTADO'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario=s.usuarioRegistra WHERE s.idSolicitud=@id AND u.activo=1;
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- ASIGNAR UNIDAD  @json: { "idSolicitud": 1, "placa": "T8A-111" }
CREATE OR ALTER PROCEDURE TRANSPORTE_asignarUnidad
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @cantidad INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @id);

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END
    IF @cantidad > @capacidad BEGIN RAISERROR('La cantidad solicitada supera la capacidad de la unidad', 16, 1); RETURN; END

    UPDATE TP_SOLICITUDES
    SET placa = @placa, estado = 'ASIGNADO'
    WHERE idSolicitud = @id;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Solicitud #', @id, ' asignada a la unidad ', @placa), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;
    -- RF-038: notificar al supervisor que registró la solicitud
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud asignada', CONCAT('Su solicitud #', @id, ' fue asignada a la unidad ', @placa), 'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @id AND u.activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @id, 'ASIGNAR_UNIDAD', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- UNIR SOLICITUDES  @json: { "ids": [1,2,3], "placa": "T8A-111" }
-- Crea un traslado cabecera, asigna placa + traslado a cada solicitud,
-- y arma la ruta con los puntos ordenados (partida de cada una + llegada final)
CREATE OR ALTER PROCEDURE TRANSPORTE_unirSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idTraslado INT;
    DECLARE @ruta NVARCHAR(1000);
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @totalPersonas INT = (
        SELECT COALESCE(SUM(s.cantidad), 0)
        FROM TP_SOLICITUDES s
        JOIN OPENJSON(@json, '$.ids') j ON s.idSolicitud = TRY_CAST(j.value AS INT)
    );

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END
    IF @totalPersonas > @capacidad BEGIN RAISERROR('Las solicitudes superan la capacidad de la unidad', 16, 1); RETURN; END

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

    -- Concatenar con FOR XML PATH en lugar de STRING_AGG (SQL Server 2016+)
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

    -- Notificar al conductor de la unidad
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Traslado T-', @idTraslado, ' asignado a la unidad ', @placa), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;
    -- RF-038: notificar a los supervisores que registraron cada solicitud
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud asignada', CONCAT('Su solicitud #', s.idSolicitud, N' se unió al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idTraslado = @idTraslado AND u.activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('TRASLADO', @idTraslado, 'UNIR_SOLICITUDES', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT t.idTraslado, t.placa, t.ruta, t.estado
    FROM TP_TRASLADOS t WHERE t.idTraslado = @idTraslado
    FOR JSON PATH;
END
GO

-- SEPARAR SOLICITUD  @json: { "idSolicitud": 1 }
-- Quita la solicitud del traslado; si el traslado queda vacío se anula
CREATE OR ALTER PROCEDURE TRANSPORTE_separarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idTraslado INT = (SELECT idTraslado FROM TP_SOLICITUDES WHERE idSolicitud = @id);

    UPDATE TP_SOLICITUDES
    SET idTraslado = NULL, placa = NULL, estado = 'PENDIENTE'
    WHERE idSolicitud = @id;

    IF @idTraslado IS NOT NULL AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idTraslado = @idTraslado)
        UPDATE TP_TRASLADOS SET estado = 'ANULADO' WHERE idTraslado = @idTraslado;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud separada', CONCAT('Su solicitud #', @id, N' fue separada del traslado y volvió a Pendiente'), 'ESTADO'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @id AND u.activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @id, 'SEPARAR', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- LISTAR TRASLADOS  @json: { "fecha": "2026-09-25" (opcional) }
CREATE OR ALTER PROCEDURE TRANSPORTE_listarTraslados
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);

    SELECT t.idTraslado, t.placa, t.ruta, t.estado, t.fechaCreacion,
           JSON_QUERY((SELECT s.idSolicitud, s.nombre, s.horaProgramada, s.puntoPartida,
                   s.puntoLlegada, s.cantidad, s.motivo, s.realizado, s.estado, s.esEmergencia
            FROM TP_SOLICITUDES s WHERE s.idTraslado = t.idTraslado
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

-- SERVICIOS DEL CONDUCTOR  @json: { "placa": "T8A-111", "fecha": "2026-09-25" (opcional) }
CREATE OR ALTER PROCEDURE TRANSPORTE_listarServiciosConductor
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @fecha DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);

    SELECT s.idSolicitud, s.idTraslado, su.idSolicitudUnidad, s.nombre, s.area, s.fechaProgramada, s.horaProgramada,
           s.puntoPartida, s.puntoLlegada, COALESCE(su.cantidadAsignada,s.cantidad) cantidad, s.motivo, s.observacion, s.esEmergencia, @placa placa,
           CASE WHEN su.idSolicitudUnidad IS NULL THEN s.realizado ELSE CASE WHEN su.estado='REALIZADO' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END END realizado,
           COALESCE(su.estado,s.estado) estado, s.fechaInicio, s.fechaFin,
           t.ruta,
           -- RF-023: paradas ordenadas del traslado con cantidades por punto
           JSON_QUERY((SELECT p.punto, p.orden, p.cantidadSube, p.cantidadBaja
                       FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = s.idTraslado
                       ORDER BY p.orden FOR JSON PATH)) AS paradas
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_SOLICITUD_UNIDADES su ON su.idSolicitud=s.idSolicitud
    LEFT JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad
    LEFT JOIN TP_TRASLADOS t ON t.idTraslado = s.idTraslado
    WHERE (s.placa = @placa OR u.placa = @placa)
      AND s.estado <> 'ANULADO'
      AND (@fecha IS NULL OR s.fechaProgramada = @fecha)
    ORDER BY s.esEmergencia DESC, s.horaProgramada, s.idSolicitud
    FOR JSON PATH;
END
GO

-- CATALOGOS
CREATE OR ALTER PROCEDURE TRANSPORTE_listarPuntos @json NVARCHAR(MAX)
AS BEGIN SELECT idPunto, nombre, latitud, longitud FROM TP_PUNTOS WHERE activo = 1 ORDER BY nombre FOR JSON PATH; END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_listarUnidades @json NVARCHAR(MAX)
AS BEGIN
    DECLARE @fecha DATE = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE), CAST(GETDATE() AS DATE));
    SELECT u.idUnidad, u.placa, u.capacidad,
           CASE WHEN EXISTS (
               SELECT 1 FROM TP_SOLICITUDES s
               WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                 AND s.estado IN ('ASIGNADO', 'EN_RUTA')
           ) THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS disponible,
           u.capacidad - COALESCE((
               SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
               WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                 AND s.estado IN ('ASIGNADO', 'EN_RUTA')
           ), 0) AS cupoDisponible
    FROM TP_UNIDADES u WHERE u.activa = 1 ORDER BY u.placa FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_listarMotivos @json NVARCHAR(MAX)
AS BEGIN SELECT idMotivo, nombre FROM TP_MOTIVOS WHERE activo = 1 ORDER BY nombre FOR JSON PATH; END
GO

-- REPORTE  @json: { "desde": "2026-09-01", "hasta": "2026-09-30" }
CREATE OR ALTER PROCEDURE TRANSPORTE_reporteSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @desde DATE = TRY_CAST(JSON_VALUE(@json, '$.desde') AS DATE);
    DECLARE @hasta DATE = TRY_CAST(JSON_VALUE(@json, '$.hasta') AS DATE);

    SELECT s.idSolicitud, s.idTraslado, s.nombre, s.usuarioRegistra, s.area,
           s.fechaProgramada, s.horaProgramada, s.puntoPartida, s.puntoLlegada, s.cantidad,
           s.motivo, s.observacion, s.esEmergencia, s.placa, s.realizado, s.estado,
           s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    WHERE (@desde IS NULL OR s.fechaProgramada >= @desde)
      AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
      AND s.estado <> 'ANULADO'
    ORDER BY s.fechaRegistro DESC
    FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_guardarParadas
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idTraslado INT = TRY_CAST(JSON_VALUE(@json, '$.idTraslado') AS INT);
    DELETE FROM TP_TRASLADO_PARADAS WHERE idTraslado = @idTraslado;
    INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
    SELECT @idTraslado, TRY_CAST(JSON_VALUE(value, '$.idPunto') AS INT), JSON_VALUE(value, '$.punto'),
           TRY_CAST([key] AS INT) + 1, COALESCE(TRY_CAST(JSON_VALUE(value, '$.cantidadSube') AS INT), 0),
           COALESCE(TRY_CAST(JSON_VALUE(value, '$.cantidadBaja') AS INT), 0)
    FROM OPENJSON(@json, '$.paradas');

    DECLARE @ruta NVARCHAR(1000);
    SELECT @ruta = STUFF((SELECT ' > ' + punto FROM TP_TRASLADO_PARADAS
                          WHERE idTraslado = @idTraslado ORDER BY orden FOR XML PATH(''), TYPE)
                          .value('.', 'NVARCHAR(MAX)'), 1, 3, '');
    UPDATE TP_TRASLADOS SET ruta = @ruta WHERE idTraslado = @idTraslado;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('TRASLADO', @idTraslado, 'ACTUALIZAR_RUTA', JSON_VALUE(@json, '$.usuario'), @json);
    SELECT * FROM TP_TRASLADO_PARADAS WHERE idTraslado = @idTraslado ORDER BY orden FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_acoplarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idTraslado INT = TRY_CAST(JSON_VALUE(@json, '$.idTraslado') AS INT);
    DECLARE @placa NVARCHAR(20) = (SELECT placa FROM TP_TRASLADOS WHERE idTraslado = @idTraslado AND estado <> 'ANULADO');
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @ocupacion INT = (SELECT COALESCE(SUM(cantidad), 0) FROM TP_SOLICITUDES WHERE idTraslado = @idTraslado AND estado <> 'ANULADO');
    DECLARE @cantidad INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud AND estado = 'PENDIENTE');
    IF @placa IS NULL OR @cantidad IS NULL BEGIN RAISERROR('Solicitud o traslado no disponible', 16, 1); RETURN; END
    IF @ocupacion + @cantidad > @capacidad BEGIN RAISERROR('No existe cupo suficiente en el traslado', 16, 1); RETURN; END

    -- Compatibilidad geográfica: origen y destino de la solicitud deben estar a <= 10 km de algún punto de la ruta
    DECLARE @maxKm FLOAT = 10;
    DECLARE @latP DECIMAL(9,6), @lonP DECIMAL(9,6), @latL DECIMAL(9,6), @lonL DECIMAL(9,6);
    SELECT @latP = p.latitud, @lonP = p.longitud
    FROM TP_SOLICITUDES s JOIN TP_PUNTOS p ON p.nombre = s.puntoPartida AND p.activo = 1
    WHERE s.idSolicitud = @idSolicitud;
    SELECT @latL = p.latitud, @lonL = p.longitud
    FROM TP_SOLICITUDES s JOIN TP_PUNTOS p ON p.nombre = s.puntoLlegada AND p.activo = 1
    WHERE s.idSolicitud = @idSolicitud;

    IF OBJECT_ID('tempdb..#RUTA') IS NOT NULL DROP TABLE #RUTA;
    CREATE TABLE #RUTA (latitud DECIMAL(9,6), longitud DECIMAL(9,6));
    INSERT INTO #RUTA
        SELECT DISTINCT pt.latitud, pt.longitud
        FROM TP_TRASLADO_PARADAS pa JOIN TP_PUNTOS pt ON pt.nombre = pa.punto AND pt.activo = 1
        WHERE pa.idTraslado = @idTraslado AND pt.latitud IS NOT NULL AND pt.longitud IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM #RUTA)
        INSERT INTO #RUTA
            SELECT DISTINCT pt.latitud, pt.longitud
            FROM TP_SOLICITUDES s JOIN TP_PUNTOS pt ON pt.activo = 1
                AND (pt.nombre = s.puntoPartida OR pt.nombre = s.puntoLlegada)
            WHERE s.idTraslado = @idTraslado AND pt.latitud IS NOT NULL AND pt.longitud IS NOT NULL;

    IF EXISTS (SELECT 1 FROM #RUTA) AND (@latP IS NOT NULL OR @latL IS NOT NULL)
    BEGIN
        IF @latP IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM #RUTA r
            WHERE 6371 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(r.latitud - @latP) / 2.0), 2) +
                COS(RADIANS(@latP)) * COS(RADIANS(r.latitud)) *
                POWER(SIN(RADIANS(r.longitud - @lonP) / 2.0), 2))) <= @maxKm)
        BEGIN RAISERROR(N'El punto de partida está a más de 10 km de la ruta del traslado', 16, 1); RETURN; END

        IF @latL IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM #RUTA r
            WHERE 6371 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(r.latitud - @latL) / 2.0), 2) +
                COS(RADIANS(@latL)) * COS(RADIANS(r.latitud)) *
                POWER(SIN(RADIANS(r.longitud - @lonL) / 2.0), 2))) <= @maxKm)
        BEGIN RAISERROR(N'El punto de llegada está a más de 10 km de la ruta del traslado', 16, 1); RETURN; END
    END
    DROP TABLE #RUTA;

    UPDATE TP_SOLICITUDES SET idTraslado = @idTraslado, placa = @placa, estado = 'ASIGNADO' WHERE idSolicitud = @idSolicitud;
    -- Notificar al conductor de la unidad del traslado
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Solicitud #', @idSolicitud, N' se acopló al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'ACOPLAR', JSON_VALUE(@json, '$.usuario'), @json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_asignarMultiplesUnidades
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @requerido INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud);
    DECLARE @asignado INT;
    SELECT @asignado = SUM(TRY_CAST(JSON_VALUE(value, '$.cantidad') AS INT)) FROM OPENJSON(@json, '$.unidades');
    IF @requerido IS NULL OR @asignado <> @requerido BEGIN RAISERROR(N'La distribución debe cubrir exactamente la cantidad solicitada', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM OPENJSON(@json, '$.unidades') j
               LEFT JOIN TP_UNIDADES u ON u.placa = JSON_VALUE(j.value, '$.placa') AND u.activa = 1
               WHERE u.idUnidad IS NULL OR TRY_CAST(JSON_VALUE(j.value, '$.cantidad') AS INT) > u.capacidad)
    BEGIN RAISERROR('Una unidad no existe o excede su capacidad', 16, 1); RETURN; END
    DELETE FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @idSolicitud;
    INSERT INTO TP_SOLICITUD_UNIDADES(idSolicitud, idUnidad, cantidadAsignada)
    SELECT @idSolicitud, u.idUnidad, TRY_CAST(JSON_VALUE(j.value, '$.cantidad') AS INT)
    FROM OPENJSON(@json, '$.unidades') j JOIN TP_UNIDADES u ON u.placa = JSON_VALUE(j.value, '$.placa');
    UPDATE TP_SOLICITUDES SET placa = CASE WHEN (SELECT COUNT(*) FROM OPENJSON(@json, '$.unidades')) = 1
                                          THEN JSON_VALUE(@json, '$.unidades[0].placa') ELSE 'MULTIPLE' END,
                                  estado = 'ASIGNADO' WHERE idSolicitud = @idSolicitud;
    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT usr.idUsuario,'Nuevo servicio asignado',CONCAT('Solicitud #',@idSolicitud,' asignada a ',u.placa),'ASIGNACION'
    FROM TP_SOLICITUD_UNIDADES su JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad JOIN TP_USUARIOS usr ON usr.placa=u.placa AND usr.activo=1
    WHERE su.idSolicitud=@idSolicitud;
    -- RF-038: notificar al supervisor que registró la solicitud
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

CREATE OR ALTER PROCEDURE TRANSPORTE_administrarCatalogo
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entidad NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.entidad'));
    DECLARE @accion NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.accion'));
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.id') AS INT);
    IF @accion <> 'LISTAR' INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES(@entidad,@id,@accion,JSON_VALUE(@json,'$.usuario'),@json);
    IF @entidad = 'PUNTO'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_PUNTOS(nombre, latitud, longitud) VALUES(JSON_VALUE(@json, '$.nombre'), TRY_CAST(JSON_VALUE(@json, '$.latitud') AS DECIMAL(9,6)), TRY_CAST(JSON_VALUE(@json, '$.longitud') AS DECIMAL(9,6)));
            ELSE UPDATE TP_PUNTOS SET nombre = JSON_VALUE(@json, '$.nombre'), latitud = TRY_CAST(JSON_VALUE(@json, '$.latitud') AS DECIMAL(9,6)), longitud = TRY_CAST(JSON_VALUE(@json, '$.longitud') AS DECIMAL(9,6)), activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo) WHERE idPunto = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_PUNTOS SET activo = 0 WHERE idPunto = @id;
        SELECT idPunto, nombre, latitud, longitud, activo FROM TP_PUNTOS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    IF @entidad = 'MOTIVO'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_MOTIVOS(nombre) VALUES(JSON_VALUE(@json, '$.nombre'));
            ELSE UPDATE TP_MOTIVOS SET nombre = JSON_VALUE(@json, '$.nombre'), activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo) WHERE idMotivo = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_MOTIVOS SET activo = 0 WHERE idMotivo = @id;
        SELECT idMotivo, nombre, activo FROM TP_MOTIVOS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    IF @entidad = 'UNIDAD'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_UNIDADES(placa, capacidad) VALUES(JSON_VALUE(@json, '$.placa'), TRY_CAST(JSON_VALUE(@json, '$.capacidad') AS INT));
            ELSE UPDATE TP_UNIDADES SET placa = JSON_VALUE(@json, '$.placa'), capacidad = TRY_CAST(JSON_VALUE(@json, '$.capacidad') AS INT), activa = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activa) WHERE idUnidad = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_UNIDADES SET activa = 0 WHERE idUnidad = @id;
        SELECT idUnidad, placa, capacidad, activa AS activo FROM TP_UNIDADES ORDER BY placa FOR JSON PATH; RETURN;
    END
    IF @entidad = 'USUARIO'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_USUARIOS(usuario, claveHash, nombre, idrol, placa, area)
                VALUES(JSON_VALUE(@json, '$.usuario'), JSON_VALUE(@json, '$.claveHash'),
                       JSON_VALUE(@json, '$.nombre'), JSON_VALUE(@json, '$.idrol'), JSON_VALUE(@json, '$.placa'), JSON_VALUE(@json, '$.area'));
            ELSE UPDATE TP_USUARIOS SET nombre = JSON_VALUE(@json, '$.nombre'), idrol = JSON_VALUE(@json, '$.idrol'),
                 placa = JSON_VALUE(@json, '$.placa'), area = JSON_VALUE(@json, '$.area'), activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo),
                 claveHash = COALESCE(NULLIF(JSON_VALUE(@json, '$.claveHash'), ''), claveHash)
                 WHERE idUsuario = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_USUARIOS SET activo = 0 WHERE idUsuario = @id;
        SELECT idUsuario, usuario, nombre, idrol, placa, area, activo FROM TP_USUARIOS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    RAISERROR(N'Entidad administrativa inválida', 16, 1);
END
GO

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
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE esEmergencia = 1 AND estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalEmergencias,
      (SELECT COALESCE(AVG(CAST(DATEDIFF(MINUTE,fechaInicio,fechaFin) AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND fechaFin IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) tiempoPromedioMinutos,
      (SELECT COALESCE(AVG(CAST(CASE WHEN DATEDIFF(MINUTE,fechaRegistro,fechaInicio)<0 THEN 0 ELSE DATEDIFF(MINUTE,fechaRegistro,fechaInicio) END AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) esperaPromedioMinutos,
      (SELECT COALESCE(100.0*SUM(CASE WHEN ABS(DATEDIFF(MINUTE,DATEADD(MINUTE,DATEDIFF(MINUTE,0,TRY_CAST(horaProgramada AS TIME)),CAST(fechaProgramada AS DATETIME)),fechaInicio))<=10 THEN 1 ELSE 0 END)/NULLIF(COUNT(*),0),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) puntualidadPorcentaje,
      JSON_QUERY((SELECT s.placa, COUNT(*) viajes, SUM(s.cantidad) personas,
                         CAST(100.0 * SUM(s.cantidad) / NULLIF(COUNT(*) * MAX(u.capacidad), 0) AS DECIMAL(6,2)) ocupacionPorcentaje
                  FROM TP_SOLICITUDES s LEFT JOIN TP_UNIDADES u ON u.placa = s.placa
                  WHERE s.estado <> 'ANULADO' AND s.placa IS NOT NULL AND s.placa <> 'MULTIPLE'
                    AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  GROUP BY s.placa FOR JSON PATH)) unidades,
      JSON_QUERY((SELECT area, COUNT(*) solicitudes, SUM(cantidad) personas FROM TP_SOLICITUDES
                  WHERE estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)
                  GROUP BY area FOR JSON PATH)) areas,
      JSON_QUERY((SELECT u.nombre conductor, u.placa, COUNT(s.idSolicitud) servicios, COALESCE(SUM(s.cantidad),0) personas
                  FROM TP_USUARIOS u LEFT JOIN TP_SOLICITUDES s ON s.placa=u.placa AND s.estado='REALIZADO'
                    AND (@desde IS NULL OR s.fechaProgramada>=@desde) AND (@hasta IS NULL OR s.fechaProgramada<=@hasta)
                  WHERE u.idrol='CHTRANS' AND u.activo=1 GROUP BY u.nombre,u.placa FOR JSON PATH)) conductores
    FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_listarAuditoria @json NVARCHAR(MAX)
AS BEGIN SELECT TOP 500 idAuditoria, entidad, idEntidad, accion, usuario, detalle, fecha FROM TP_AUDITORIA ORDER BY fecha DESC FOR JSON PATH; END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_listarNotificaciones @json NVARCHAR(MAX)
AS BEGIN
    DECLARE @idUsuario INT = TRY_CAST(JSON_VALUE(@json, '$.idUsuario') AS INT);
    SELECT TOP 100 idNotificacion, titulo, mensaje, tipo, leida, fecha FROM TP_NOTIFICACIONES
    WHERE idUsuario = @idUsuario OR idUsuario IS NULL ORDER BY fecha DESC FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_marcarNotificacion @json NVARCHAR(MAX)
AS BEGIN
    DECLARE @idNotificacion BIGINT = TRY_CAST(JSON_VALUE(@json, '$.idNotificacion') AS BIGINT);
    DECLARE @idUsuario INT = TRY_CAST(JSON_VALUE(@json, '$.idUsuario') AS INT);
    UPDATE TP_NOTIFICACIONES SET leida=1 WHERE idNotificacion=@idNotificacion AND (idUsuario=@idUsuario OR idUsuario IS NULL);
    SELECT idNotificacion,titulo,mensaje,tipo,leida,fecha FROM TP_NOTIFICACIONES WHERE idNotificacion=@idNotificacion FOR JSON PATH;
END
GO

-- AGREGAR PASAJEROS DE EMERGENCIA (RF-024)
-- @json: { "idSolicitud": 1, "idSolicitudUnidad": 5 (opcional), "cantidad": 2 }
-- El conductor registra pasajeros extra si la unidad tiene cupo libre.
CREATE OR ALTER PROCEDURE TRANSPORTE_agregarPasajeros
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idSolicitudUnidad INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitudUnidad') AS INT);
    DECLARE @extra INT = TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT);

    IF @extra IS NULL OR @extra < 1 BEGIN RAISERROR(N'Cantidad de pasajeros inválida', 16, 1); RETURN; END

    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_SOLICITUD_UNIDADES
                             WHERE idSolicitudUnidad = @idSolicitudUnidad AND idSolicitud = @idSolicitud);
    DECLARE @placa NVARCHAR(20) = COALESCE((SELECT placa FROM TP_UNIDADES WHERE idUnidad = @idUnidad),
                                           (SELECT placa FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud));
    DECLARE @estado NVARCHAR(20) = COALESCE((SELECT estado FROM TP_SOLICITUD_UNIDADES WHERE idSolicitudUnidad = @idSolicitudUnidad),
                                            (SELECT estado FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud));
    DECLARE @fecha DATE = (SELECT fechaProgramada FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud);
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);

    IF @placa IS NULL OR @placa = 'MULTIPLE' AND @idUnidad IS NULL
    BEGIN RAISERROR('Servicio sin unidad asignada', 16, 1); RETURN; END
    IF @estado IS NULL OR @estado NOT IN ('ASIGNADO', 'EN_RUTA')
    BEGIN RAISERROR('Solo se pueden agregar pasajeros a servicios asignados o en ruta', 16, 1); RETURN; END
    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END

    -- Ocupación actual de la unidad en el viaje
    DECLARE @ocupacion INT;
    IF @idUnidad IS NOT NULL
        SELECT @ocupacion = COALESCE(SUM(su2.cantidadAsignada), 0)
        FROM TP_SOLICITUD_UNIDADES su2
        JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su2.idSolicitud
        WHERE su2.idUnidad = @idUnidad AND s2.fechaProgramada = @fecha AND s2.estado <> 'ANULADO';
    ELSE IF (SELECT idTraslado FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud) IS NOT NULL
        SELECT @ocupacion = COALESCE(SUM(s2.cantidad), 0)
        FROM TP_SOLICITUDES s2
        WHERE s2.idTraslado = (SELECT idTraslado FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud)
          AND s2.estado <> 'ANULADO';
    ELSE
        SELECT @ocupacion = COALESCE(SUM(s2.cantidad), 0)
        FROM TP_SOLICITUDES s2
        WHERE s2.placa = @placa AND s2.fechaProgramada = @fecha
          AND s2.estado IN ('ASIGNADO', 'EN_RUTA');

    IF @ocupacion + @extra > @capacidad
    BEGIN RAISERROR('No hay cupo suficiente en la unidad', 16, 1); RETURN; END

    IF @idUnidad IS NOT NULL
        UPDATE TP_SOLICITUD_UNIDADES SET cantidadAsignada = cantidadAsignada + @extra
        WHERE idSolicitudUnidad = @idSolicitudUnidad;
    UPDATE TP_SOLICITUDES SET cantidad = cantidad + @extra, esEmergencia = 1 WHERE idSolicitud = @idSolicitud;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'AGREGAR_PASAJEROS', JSON_VALUE(@json, '$.usuario'), @json);
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Pasajeros agregados', CONCAT(N'El conductor agregó ', @extra, ' pasajero(s) a la solicitud #', @idSolicitud), 'PASAJEROS'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @idSolicitud AND u.activo = 1;

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

-- Repara texto con encoding dañado en notificaciones ya registradas
UPDATE TP_NOTIFICACIONES
SET titulo  = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(titulo, N'Ã³', N'ó'), N'Ã­', N'í'), N'Ã©', N'é'), N'Ã¡', N'á'), N'Ã±', N'ñ'), N'Ãº', N'ú'), N'Ã', N'Á'),
    mensaje = REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(mensaje, N'Ã³', N'ó'), N'Ã­', N'í'), N'Ã©', N'é'), N'Ã¡', N'á'), N'Ã±', N'ñ'), N'Ãº', N'ú'), N'Ã', N'Á')
WHERE titulo LIKE N'%Ã%' OR mensaje LIKE N'%Ã%';
GO
