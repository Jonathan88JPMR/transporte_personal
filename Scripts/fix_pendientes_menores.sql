-- =====================================================================
-- Pendientes menores del review
-- 1) listarSolicitudes: supervisor SIN area solo ve sus propias solicitudes
--    (antes veia todas porque el filtro por area quedaba NULL)
-- 2) acoplarSolicitud: un supervisor solo puede acoplar solicitudes de su
--    propia area (guarda server-side)
-- =====================================================================

CREATE OR ALTER PROCEDURE TRANSPORTE_listarSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha  DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);
    DECLARE @estado NVARCHAR(20) = JSON_VALUE(@json, '$.estado');
    DECLARE @usuario NVARCHAR(50) = JSON_VALUE(@json, '$.usuario');
    -- Si quien consulta es supervisor, solo ve solicitudes de su area
    DECLARE @idAreaFiltro INT = (SELECT idArea FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS');
    DECLARE @esSupervisor BIT = CASE WHEN EXISTS (SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS') THEN 1 ELSE 0 END;

    SELECT s.idSolicitud, s.idTraslado, s.idArea, s.nombre, COALESCE(a.nombre, s.area) AS area,
           s.fechaProgramada, s.horaProgramada, s.puntoPartida, s.puntoLlegada, s.cantidad,
           s.motivo, s.observacion, s.prioridad, s.esEmergencia, s.placa,
           s.realizado, s.estado, s.usuarioRegistra, s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
    WHERE (@fecha  IS NULL OR s.fechaProgramada = @fecha)
      AND (@estado IS NULL OR s.estado = @estado)
      AND (@usuario IS NULL OR @esSupervisor = 0
           OR s.idArea = @idAreaFiltro
           OR (@idAreaFiltro IS NULL AND s.usuarioRegistra = @usuario))
    -- RN-004: prioridad primero (emergencias al tope), luego orden de registro
    ORDER BY CASE s.prioridad WHEN 'EMERGENCIA' THEN 0 WHEN 'ALTA' THEN 1 ELSE 2 END,
             s.fechaRegistro, s.idSolicitud
    FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_acoplarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idTraslado INT = TRY_CAST(JSON_VALUE(@json, '$.idTraslado') AS INT);
    DECLARE @usuario NVARCHAR(50) = JSON_VALUE(@json, '$.usuario');
    DECLARE @placa NVARCHAR(20) = (SELECT placa FROM TP_TRASLADOS WHERE idTraslado = @idTraslado AND estado <> 'ANULADO');
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @ocupacion INT = (SELECT COALESCE(SUM(cantidad), 0) FROM TP_SOLICITUDES WHERE idTraslado = @idTraslado AND estado <> 'ANULADO');
    DECLARE @cantidad INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud AND estado = 'PENDIENTE');
    IF @placa IS NULL OR @cantidad IS NULL BEGIN RAISERROR('Solicitud o traslado no disponible', 16, 1); RETURN; END

    -- Un supervisor solo puede acoplar solicitudes de su propia area
    IF EXISTS (SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS')
       AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES s
                       JOIN TP_USUARIOS u ON u.usuario = @usuario AND u.idArea = s.idArea
                       WHERE s.idSolicitud = @idSolicitud)
    BEGIN RAISERROR('Solo puede acoplar solicitudes de su propia area', 16, 1); RETURN; END

    IF @ocupacion + @cantidad > @capacidad BEGIN RAISERROR('No existe cupo suficiente en el traslado', 16, 1); RETURN; END

    -- Compatibilidad geografica: origen y destino de la solicitud deben estar a <= 10 km de algun punto de la ruta
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
        BEGIN RAISERROR(N'El punto de partida esta a mas de 10 km de la ruta del traslado', 16, 1); RETURN; END

        IF @latL IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM #RUTA r
            WHERE 6371 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(r.latitud - @latL) / 2.0), 2) +
                COS(RADIANS(@latL)) * COS(RADIANS(r.latitud)) *
                POWER(SIN(RADIANS(r.longitud - @lonL) / 2.0), 2))) <= @maxKm)
        BEGIN RAISERROR(N'El punto de llegada esta a mas de 10 km de la ruta del traslado', 16, 1); RETURN; END
    END
    DROP TABLE #RUTA;

    UPDATE TP_SOLICITUDES SET idTraslado = @idTraslado, placa = @placa, estado = 'ASIGNADO' WHERE idSolicitud = @idSolicitud;
    -- Notificar al conductor de la unidad del traslado
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Solicitud #', @idSolicitud, ' se acoplo al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'ACOPLAR', JSON_VALUE(@json, '$.usuario'), @json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO
