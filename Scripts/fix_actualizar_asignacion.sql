-- =====================================================================
-- Reasignar unidad por falla mecanica + editar servicio ASIGNADO
--
-- El coordinador necesitaba cambiar la placa de un servicio ya asignado
-- (unidad averiada) sin desasignar/reasignar a mano, y corregir datos del
-- servicio (hora requerida, puntos, cantidad) en servicios planificados.
-- Hoy no hay via: guardarSolicitud solo acepta PENDIENTE y desasignar
-- exige idTraslado NULL (V2 siempre crea traslado implicito).
--
-- TRANSPORTE_actualizarAsignacion @json:
--   { "idSolicitud":1, "placa":"T8A-127" (opcional),
--     "horaRequerida":"18:30", "puntoPartida":"...", "puntoLlegada":"...",
--     "cantidad":5, "usuario":"coord" }
--
-- Reglas:
-- - Solo servicios ASIGNADO y con todas sus paradas PENDIENTE
--   (un servicio EN_RUTA/A_BORDO/REALIZADO no se toca).
-- - Cambio de placa: mueve TODO el traslado de la solicitud a la unidad
--   nueva (un traslado es una sola unidad fisica). Notifica al conductor
--   anterior (ESTADO, en campanita) y al nuevo (ASIGNACION con
--   fechaServicio → suena/vibra/push solo si el servicio es de hoy).
-- - Cambio de puntos/cantidad: reconstruye paradas y detalles del
--   traslado fusionando por punto (mismo algoritmo que unirSolicitudes).
--   En asignacion MULTIPLE los puntos se propagan a los traslados de
--   cada porcion; placa y cantidad se gestionan con "Varias".
-- - Todo cambio queda en TP_AUDITORIA.
-- =====================================================================
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_actualizarAsignacion
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @estado NVARCHAR(20), @placaActual NVARCHAR(20), @idTraslado INT;
    SELECT @estado = estado, @placaActual = placa, @idTraslado = idTraslado
      FROM TP_SOLICITUDES WHERE idSolicitud = @id;

    IF @estado IS NULL
    BEGIN RAISERROR('Solicitud inexistente', 16, 1); RETURN; END
    IF @estado <> 'ASIGNADO'
    BEGIN RAISERROR('Solo se puede modificar un servicio ASIGNADO (sin iniciar recorrido)', 16, 1); RETURN; END
    IF EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS p
               WHERE p.estado <> 'PENDIENTE'
                 AND (p.idTraslado = @idTraslado
                      OR p.idTraslado IN (SELECT idTraslado FROM TP_SOLICITUD_UNIDADES
                                          WHERE idSolicitud = @id)))
    BEGIN RAISERROR('El recorrido ya inicio; no se puede modificar', 16, 1); RETURN; END

    DECLARE @placaNueva NVARCHAR(20)  = NULLIF(JSON_VALUE(@json, '$.placa'), '');
    DECLARE @hora  NVARCHAR(10)  = NULLIF(JSON_VALUE(@json, '$.horaRequerida'), '');
    DECLARE @pp    NVARCHAR(150) = NULLIF(JSON_VALUE(@json, '$.puntoPartida'), '');
    DECLARE @pl    NVARCHAR(150) = NULLIF(JSON_VALUE(@json, '$.puntoLlegada'), '');
    DECLARE @cant  INT = TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT);
    IF @cant IS NOT NULL AND @cant < 1
    BEGIN RAISERROR('Cantidad invalida', 16, 1); RETURN; END

    -- Asignacion multiple: unidades y cantidad se reparten con "Varias"
    IF @placaActual = 'MULTIPLE'
    BEGIN
        IF @placaNueva IS NOT NULL AND @placaNueva <> @placaActual
        BEGIN RAISERROR('La asignacion es multiple: cambie las unidades con la opcion "Varias"', 16, 1); RETURN; END
        IF @cant IS NOT NULL AND @cant <> (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @id)
        BEGIN RAISERROR('La asignacion es multiple: la cantidad se redistribuye con la opcion "Varias"', 16, 1); RETURN; END
        SET @placaNueva = NULL;
        SET @cant = NULL;
    END

    -- Datos del servicio (solo lo que se envio)
    UPDATE TP_SOLICITUDES
    SET horaRequerida = COALESCE(@hora, horaRequerida),
        puntoPartida  = COALESCE(@pp, puntoPartida),
        puntoLlegada  = COALESCE(@pl, puntoLlegada),
        cantidad      = COALESCE(@cant, cantidad)
    WHERE idSolicitud = @id;

    DECLARE @cambiaRuta BIT = CASE WHEN @pp IS NOT NULL OR @pl IS NOT NULL OR @cant IS NOT NULL THEN 1 ELSE 0 END;
    DECLARE @cambiaDato BIT = CASE WHEN @hora IS NOT NULL OR @cambiaRuta = 1 THEN 1 ELSE 0 END;

    -- Las alertas de asignaciones previas de esta solicitud/traslado quedan
    -- obsoletas: se marcan leidas para no duplicar el aviso al conductor
    IF (@placaNueva IS NOT NULL AND @placaNueva <> @placaActual) OR @cambiaDato = 1
        UPDATE TP_NOTIFICACIONES SET leida = 1
        WHERE tipo = 'ASIGNACION' AND leida = 0
          AND (mensaje LIKE '%#' + CAST(@id AS VARCHAR(10)) + ' %'
               OR mensaje LIKE '%#' + CAST(@id AS VARCHAR(10))
               OR mensaje LIKE '%T-' + CAST(@idTraslado AS VARCHAR(10)) + ' %'
               OR mensaje LIKE '%T-' + CAST(@idTraslado AS VARCHAR(10)));

    -- ===== Cambio de unidad: mueve todo el traslado =====
    IF @placaNueva IS NOT NULL AND @placaNueva <> @placaActual
    BEGIN
        IF NOT EXISTS (SELECT 1 FROM TP_UNIDADES WHERE placa = @placaNueva AND activa = 1 AND estadoOperativo = 'OPERATIVA')
        BEGIN RAISERROR('Unidad inexistente, inactiva o no operativa', 16, 1); RETURN; END

        UPDATE TP_TRASLADOS SET placa = @placaNueva WHERE idTraslado = @idTraslado;
        UPDATE TP_SOLICITUDES SET placa = @placaNueva
        WHERE idTraslado = @idTraslado OR (@idTraslado IS NULL AND idSolicitud = @id);

        DECLARE @fs DATE = (SELECT MAX(fechaProgramada) FROM TP_SOLICITUDES
                            WHERE idTraslado = @idTraslado OR (@idTraslado IS NULL AND idSolicitud = @id));
        -- Conductor anterior: aviso en campanita (sin sonar como asignacion)
        INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo, fechaServicio)
        SELECT usr.idUsuario, 'Servicio reasignado',
               CONCAT('El servicio ', CASE WHEN @idTraslado IS NOT NULL
                       THEN CONCAT('(traslado T-', @idTraslado, ') ') ELSE CONCAT('#', @id, ' ') END,
                      'de la unidad ', @placaActual, ' fue reasignado a ', @placaNueva),
               'ESTADO', @fs
        FROM TP_USUARIOS usr WHERE usr.placa = @placaActual AND usr.activo = 1;
        -- Conductor nuevo: alerta completa (suena/push si el servicio es de hoy)
        INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo, fechaServicio)
        SELECT usr.idUsuario, 'Nuevo servicio asignado',
               CONCAT(CASE WHEN @idTraslado IS NOT NULL
                       THEN CONCAT('Traslado T-', @idTraslado) ELSE CONCAT('Solicitud #', @id) END,
                      ' reasignado a la unidad ', @placaNueva),
               'ASIGNACION', @fs
        FROM TP_USUARIOS usr WHERE usr.placa = @placaNueva AND usr.activo = 1;
    END

    -- ===== Reconstruir paradas del traslado (puntos o cantidad) =====
    IF @cambiaRuta = 1 AND @idTraslado IS NOT NULL
    BEGIN
        -- Eventos S/B por solicitud del traslado; orden por hora requerida
        DECLARE @Eventos TABLE (solOrd INT, evOrd INT, idSolicitud INT,
                                punto NVARCHAR(150), tipo CHAR(1), cantidad INT);
        INSERT INTO @Eventos
        SELECT ROW_NUMBER() OVER (ORDER BY COALESCE(s.horaRequerida, s.horaProgramada), s.idSolicitud),
               0, s.idSolicitud, s.puntoPartida, 'S', s.cantidad
        FROM TP_SOLICITUDES s
        WHERE s.idTraslado = @idTraslado AND s.estado <> 'ANULADO';
        INSERT INTO @Eventos
        SELECT e.solOrd, 1, s.idSolicitud, s.puntoLlegada, 'B', s.cantidad
        FROM TP_SOLICITUDES s
        JOIN @Eventos e ON e.idSolicitud = s.idSolicitud AND e.evOrd = 0
        WHERE s.idTraslado = @idTraslado AND s.estado <> 'ANULADO';

        DELETE d FROM TP_PARADA_DETALLE d
        JOIN TP_TRASLADO_PARADAS p ON p.idParada = d.idParada
        WHERE p.idTraslado = @idTraslado;
        DELETE FROM TP_TRASLADO_PARADAS WHERE idTraslado = @idTraslado;

        INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
        SELECT @idTraslado, pt.idPunto, pl.punto,
               ROW_NUMBER() OVER (ORDER BY pl.posMin), pl.sube, pl.baja
        FROM (SELECT e.punto, MIN(e.solOrd * 2 + e.evOrd) posMin,
                     ISNULL(SUM(CASE WHEN e.tipo = 'S' THEN e.cantidad END), 0) sube,
                     ISNULL(SUM(CASE WHEN e.tipo = 'B' THEN e.cantidad END), 0) baja
              FROM @Eventos e GROUP BY e.punto) pl
        LEFT JOIN TP_PUNTOS pt ON pt.nombre = pl.punto AND pt.activo = 1;

        INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
        SELECT p.idParada, e.idSolicitud, e.tipo, e.cantidad
        FROM @Eventos e
        JOIN TP_TRASLADO_PARADAS p ON p.idTraslado = @idTraslado AND p.punto = e.punto;

        UPDATE TP_TRASLADOS SET ruta = STUFF((
            SELECT ' > ' + punto FROM TP_TRASLADO_PARADAS
            WHERE idTraslado = @idTraslado ORDER BY orden
            FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, '')
        WHERE idTraslado = @idTraslado;
    END

    -- ===== Asignacion MULTIPLE: propagar puntos a cada porcion =====
    IF @pp IS NOT NULL OR @pl IS NOT NULL
    BEGIN
        DECLARE @suT INT, @suCant INT, @suId INT;
        DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
            SELECT su.idTraslado, su.cantidadAsignada, su.idSolicitudUnidad
            FROM TP_SOLICITUD_UNIDADES su
            WHERE su.idSolicitud = @id AND su.idTraslado IS NOT NULL;
        OPEN cur; FETCH NEXT FROM cur INTO @suT, @suCant, @suId;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            DELETE d FROM TP_PARADA_DETALLE d
            JOIN TP_TRASLADO_PARADAS p ON p.idParada = d.idParada
            WHERE p.idTraslado = @suT;
            DELETE FROM TP_TRASLADO_PARADAS WHERE idTraslado = @suT;

            INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
            SELECT @suT, pt.idPunto, s.puntoPartida, 1, @suCant,
                   CASE WHEN s.puntoPartida = s.puntoLlegada THEN @suCant ELSE 0 END
            FROM TP_SOLICITUDES s
            LEFT JOIN TP_PUNTOS pt ON pt.nombre = s.puntoPartida AND pt.activo = 1
            WHERE s.idSolicitud = @id;
            INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, idSolicitudUnidad, tipo, cantidadPlaneada)
            SELECT p.idParada, @id, @suId, 'S', @suCant
            FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = @suT;

            IF (SELECT puntoPartida FROM TP_SOLICITUDES WHERE idSolicitud = @id)
               <> (SELECT puntoLlegada FROM TP_SOLICITUDES WHERE idSolicitud = @id)
            BEGIN
                INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
                SELECT @suT, pt.idPunto, s.puntoLlegada, 2, 0, @suCant
                FROM TP_SOLICITUDES s
                LEFT JOIN TP_PUNTOS pt ON pt.nombre = s.puntoLlegada AND pt.activo = 1
                WHERE s.idSolicitud = @id;
            END
            -- Detalle de bajada en la parada de llegada (o la unica, si partida = llegada)
            INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, idSolicitudUnidad, tipo, cantidadPlaneada)
            SELECT TOP 1 p.idParada, @id, @suId, 'B', @suCant
            FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = @suT
            ORDER BY p.orden DESC;

            UPDATE TP_TRASLADOS SET ruta = (SELECT CONCAT(puntoPartida, ' > ', puntoLlegada)
                                            FROM TP_SOLICITUDES WHERE idSolicitud = @id)
            WHERE idTraslado = @suT;
            FETCH NEXT FROM cur INTO @suT, @suCant, @suId;
        END
        CLOSE cur; DEALLOCATE cur;
    END

    -- ===== Aviso a conductores del cambio de datos =====
    IF @cambiaDato = 1
    BEGIN
        INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo, fechaServicio)
        SELECT DISTINCT usr.idUsuario, 'Servicio modificado',
               CONCAT('La solicitud #', @id, ' fue modificada por el coordinador (hora/ruta/cantidad)'),
               'ASIGNACION', s.fechaProgramada
        FROM TP_SOLICITUDES s
        LEFT JOIN TP_SOLICITUD_UNIDADES su ON su.idSolicitud = s.idSolicitud
        LEFT JOIN TP_UNIDADES un ON un.idUnidad = su.idUnidad
        JOIN TP_USUARIOS usr ON usr.placa = COALESCE(un.placa, s.placa) AND usr.activo = 1
        WHERE s.idSolicitud = @id;
        -- Supervisor que registro la solicitud
        INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo, fechaServicio)
        SELECT u.idUsuario, 'Solicitud modificada',
               CONCAT('Su solicitud #', @id, ' fue modificada por el coordinador'),
               'ESTADO', s.fechaProgramada
        FROM TP_SOLICITUDES s
        JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
        WHERE s.idSolicitud = @id AND u.activo = 1;
    END

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @id, 'ACTUALIZAR_ASIGNACION', JSON_VALUE(@json, '$.usuario'), @json);

    -- Una fila por unidad afectada: el API usa placa+fechaProgramada para el push
    SELECT s.idSolicitud, COALESCE(un.placa, s.placa) AS placa,
           s.fechaProgramada, s.estado
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_SOLICITUD_UNIDADES su ON su.idSolicitud = s.idSolicitud
    LEFT JOIN TP_UNIDADES un ON un.idUnidad = su.idUnidad
    WHERE s.idSolicitud = @id
    FOR JSON PATH;
END
GO
