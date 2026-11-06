
/* asignarUnidad: ademǭs de activa=1 exige estadoOperativo='OPERATIVA'
   (una unidad en mantenimiento o fuera de servicio no puede asignarse). */
CREATE   PROCEDURE TRANSPORTE_asignarUnidad
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1 AND estadoOperativo = 'OPERATIVA');
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1 AND estadoOperativo = 'OPERATIVA');
    DECLARE @cantidad INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @id);
    DECLARE @fecha DATE = (SELECT fechaProgramada FROM TP_SOLICITUDES WHERE idSolicitud = @id);

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente, inactiva o no operativa', 16, 1); RETURN; END
    IF @cantidad IS NULL BEGIN RAISERROR('Solicitud inexistente', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND estado = 'PENDIENTE')
    BEGIN RAISERROR('La solicitud no esta pendiente de asignacion', 16, 1); RETURN; END

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

    DECLARE @pp NVARCHAR(300), @pl NVARCHAR(300);
    SELECT @pp = puntoPartida, @pl = puntoLlegada FROM TP_SOLICITUDES WHERE idSolicitud = @id;

    -- Traslado implicito (una sola solicitud)
    INSERT INTO TP_TRASLADOS (placa, ruta) VALUES (@placa, CONCAT(@pp, ' > ', @pl));
    DECLARE @idTraslado INT = SCOPE_IDENTITY();

    UPDATE TP_SOLICITUDES
    SET placa = @placa, estado = 'ASIGNADO', idTraslado = @idTraslado
    WHERE idSolicitud = @id;

    -- Paradas base A -> B (si partida = llegada, una sola parada con ambos)
    INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
    SELECT @idTraslado, pt.idPunto, v.punto, v.orden, v.sube, v.baja
    FROM (VALUES (@pp, 1, @cantidad, CASE WHEN @pp = @pl THEN @cantidad ELSE 0 END),
                 (@pl, 2, 0, @cantidad)) v(punto, orden, sube, baja)
    LEFT JOIN TP_PUNTOS pt ON pt.nombre = v.punto AND pt.activo = 1
    WHERE NOT (@pp = @pl AND v.orden = 2);

    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    SELECT p.idParada, @id,
           CASE WHEN p.orden = 1 THEN 'S' ELSE 'B' END, @cantidad
    FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = @idTraslado;
    -- Caso partida = llegada: un solo punto recibe ambos detalles
    IF @pp = @pl
        INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
        SELECT TOP 1 p.idParada, @id, 'B', @cantidad
        FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = @idTraslado ORDER BY p.orden;

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

