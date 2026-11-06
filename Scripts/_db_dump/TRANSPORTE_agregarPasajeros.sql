
-- ----------------------------------------------------------------------------
-- 8) agregarPasajeros: el detalle del extra tambien registra la porcion
-- ----------------------------------------------------------------------------
CREATE PROCEDURE TRANSPORTE_agregarPasajeros
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idSolicitudUnidad INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitudUnidad') AS INT);
    DECLARE @idParada INT = TRY_CAST(JSON_VALUE(@json, '$.idParada') AS INT);
    DECLARE @extra INT = TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT);

    IF @extra IS NULL OR @extra < 1 BEGIN RAISERROR(N'Cantidad de pasajeros invalida', 16, 1); RETURN; END

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
        UPDATE TP_SOLICITUD_UNIDADES SET cantidadAsignada = cantidadAsignada + @extra, esEmergencia = 1
        WHERE idSolicitudUnidad = @idSolicitudUnidad;
    ELSE
        UPDATE TP_SOLICITUDES SET esEmergencia = 1, prioridad = 'EMERGENCIA' WHERE idSolicitud = @idSolicitud;
    UPDATE TP_SOLICITUDES SET cantidad = cantidad + @extra WHERE idSolicitud = @idSolicitud;

    -- Si el extra sube en una parada concreta, quedar registrado ahi
    IF @idParada IS NOT NULL
    BEGIN
        UPDATE TP_TRASLADO_PARADAS
        SET cantidadSube  = CASE WHEN estado = 'PENDIENTE' THEN cantidadSube + @extra ELSE cantidadSube END,
            subieronReal  = CASE WHEN estado = 'EN_PARADA' THEN COALESCE(subieronReal, cantidadSube, 0) + @extra ELSE subieronReal END
        WHERE idParada = @idParada AND estado IN ('PENDIENTE','EN_PARADA');

        IF EXISTS (SELECT 1 FROM TP_PARADA_DETALLE
                   WHERE idParada = @idParada AND idSolicitud = @idSolicitud AND tipo = 'S'
                     AND (idSolicitudUnidad = @idSolicitudUnidad OR (@idSolicitudUnidad IS NULL AND idSolicitudUnidad IS NULL)))
            UPDATE TP_PARADA_DETALLE
            SET cantidadPlaneada = cantidadPlaneada + @extra,
                cantidadReal = CASE WHEN cantidadReal IS NOT NULL THEN cantidadReal + @extra ELSE cantidadReal END
            WHERE idParada = @idParada AND idSolicitud = @idSolicitud AND tipo = 'S'
              AND (idSolicitudUnidad = @idSolicitudUnidad OR (@idSolicitudUnidad IS NULL AND idSolicitudUnidad IS NULL));
        ELSE IF EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada)
            INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, idSolicitudUnidad, tipo, cantidadPlaneada)
            VALUES (@idParada, @idSolicitud, @idSolicitudUnidad, 'S', @extra);
    END

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'AGREGAR_PASAJEROS', JSON_VALUE(@json, '$.usuario'), @json);
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Pasajeros agregados', CONCAT(N'El conductor agrego ', @extra, ' pasajero(s) a la solicitud #', @idSolicitud), 'PASAJEROS'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @idSolicitud AND u.activo = 1;

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END

