
-- ----------------------------------------------------------------------------
-- unirSolicitudes: autogenera paradas fusionando puntos repetidos
-- (cada punto una vez, orden de primera aparicion por orden de seleccion)
-- ----------------------------------------------------------------------------
CREATE   PROCEDURE TRANSPORTE_unirSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idTraslado INT;
    DECLARE @ruta NVARCHAR(1000);
    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);

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

    -- Eventos S/B por solicitud: partida antes que llegada (evOrd 0/1)
    DECLARE @Eventos TABLE (solOrd INT, evOrd INT, idSolicitud INT,
                            punto NVARCHAR(300), tipo CHAR(1), cantidad INT);
    INSERT INTO @Eventos
    SELECT i.orden, 0, s.idSolicitud, s.puntoPartida, 'S', s.cantidad
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud;
    INSERT INTO @Eventos
    SELECT i.orden, 1, s.idSolicitud, s.puntoLlegada, 'B', s.cantidad
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud;

    -- Ruta: puntos unicos en orden de primera aparicion
    SELECT @ruta = STUFF((
        SELECT ' > ' + punto FROM (
            SELECT punto, MIN(solOrd * 2 + evOrd) AS posMin
            FROM @Eventos GROUP BY punto) p
        ORDER BY posMin
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, '');

    INSERT INTO TP_TRASLADOS (placa, ruta) VALUES (@placa, @ruta);
    SET @idTraslado = SCOPE_IDENTITY();

    -- Paradas fusionadas por punto
    INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
    SELECT @idTraslado, pt.idPunto, pl.punto,
           ROW_NUMBER() OVER (ORDER BY pl.posMin),
           pl.sube, pl.baja
    FROM (SELECT punto, MIN(solOrd * 2 + evOrd) AS posMin,
                 ISNULL(SUM(CASE WHEN tipo = 'S' THEN cantidad END), 0) AS sube,
                 ISNULL(SUM(CASE WHEN tipo = 'B' THEN cantidad END), 0) AS baja
          FROM @Eventos GROUP BY punto) pl
    LEFT JOIN TP_PUNTOS pt ON pt.nombre = pl.punto AND pt.activo = 1;

    -- Detalle parada <-> solicitud
    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    SELECT p.idParada, e.idSolicitud, e.tipo, e.cantidad
    FROM @Eventos e
    JOIN TP_TRASLADO_PARADAS p ON p.idTraslado = @idTraslado AND p.punto = e.punto;

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

