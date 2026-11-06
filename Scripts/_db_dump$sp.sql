
-- ----------------------------------------------------------------------------
-- acoplarSolicitud: fusiona los puntos de la solicitud con las paradas
-- pendientes del traslado (suma al punto existente o agrega al final).
-- ----------------------------------------------------------------------------
CREATE   PROCEDURE TRANSPORTE_acoplarSolicitud
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

    IF EXISTS (SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS')
       AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES s
                       JOIN TP_USUARIOS u ON u.usuario = @usuario AND u.idArea = s.idArea
                       WHERE s.idSolicitud = @idSolicitud)
    BEGIN RAISERROR('Solo puede acoplar solicitudes de su propia area', 16, 1); RETURN; END

    IF @ocupacion + @cantidad > @capacidad BEGIN RAISERROR('No existe cupo suficiente en el traslado', 16, 1); RETURN; END

    -- La ruta no debe estar en ejecucion para modificar sus paradas
    IF EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS
               WHERE idTraslado = @idTraslado AND estado <> 'PENDIENTE')
    BEGIN RAISERROR('El traslado ya inicio su recorrido', 16, 1); RETURN; END

    -- Compatibilidad geografica: origen y destino a <= 10 km de la ruta
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

    -- Fusionar puntos de la solicitud con las paradas pendientes
    DECLARE @pp NVARCHAR(300), @pl2 NVARCHAR(300), @maxOrden INT, @idParadaP INT;
    SELECT @pp = puntoPartida, @pl2 = puntoLlegada FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud;
    SELECT @maxOrden = ISNULL(MAX(orden), 0) FROM TP_TRASLADO_PARADAS WHERE idTraslado = @idTraslado;

    -- Punto de partida (suben)
    SELECT @idParadaP = MIN(idParada) FROM TP_TRASLADO_PARADAS
    WHERE idTraslado = @idTraslado AND punto = @pp AND estado = 'PENDIENTE';
    IF @idParadaP IS NULL
    BEGIN
        SET @maxOrden = @maxOrden + 1;
        INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
        SELECT @idTraslado, pt.idPunto, @pp, @maxOrden, @cantidad, 0
        FROM TP_PUNTOS pt WHERE pt.nombre = @pp AND pt.activo = 1;
        IF @@ROWCOUNT = 0
            INSERT INTO TP_TRASLADO_PARADAS (idTraslado, punto, orden, cantidadSube, cantidadBaja)
            VALUES (@idTraslado, @pp, @maxOrden, @cantidad, 0);
        SET @idParadaP = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE TP_TRASLADO_PARADAS SET cantidadSube = cantidadSube + @cantidad WHERE idParada = @idParadaP;

    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    VALUES (@idParadaP, @idSolicitud, 'S', @cantidad);

    -- Punto de llegada (bajan)
    SET @idParadaP = NULL;
    SELECT @idParadaP = MIN(idParada) FROM TP_TRASLADO_PARADAS
    WHERE idTraslado = @idTraslado AND punto = @pl2 AND estado = 'PENDIENTE';
    IF @idParadaP IS NULL
    BEGIN
        SET @maxOrden = @maxOrden + 1;
        INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
        SELECT @idTraslado, pt.idPunto, @pl2, @maxOrden, 0, @cantidad
        FROM TP_PUNTOS pt WHERE pt.nombre = @pl2 AND pt.activo = 1;
        IF @@ROWCOUNT = 0
            INSERT INTO TP_TRASLADO_PARADAS (idTraslado, punto, orden, cantidadSube, cantidadBaja)
            VALUES (@idTraslado, @pl2, @maxOrden, 0, @cantidad);
        SET @idParadaP = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE TP_TRASLADO_PARADAS SET cantidadBaja = cantidadBaja + @cantidad WHERE idParada = @idParadaP;

    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    VALUES (@idParadaP, @idSolicitud, 'B', @cantidad);

    -- Recalcular la ruta textual
    DECLARE @ruta NVARCHAR(2000);
    SELECT @ruta = STUFF((SELECT ' > ' + punto FROM TP_TRASLADO_PARADAS
                          WHERE idTraslado = @idTraslado ORDER BY orden
                          FOR XML PATH(''),TYPE).value('.','NVARCHAR(MAX)'),1,3,'');
    UPDATE TP_TRASLADOS SET ruta = @ruta WHERE idTraslado = @idTraslado;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Solicitud #', @idSolicitud, ' se acoplo al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'ACOPLAR', JSON_VALUE(@json, '$.usuario'), @json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END

