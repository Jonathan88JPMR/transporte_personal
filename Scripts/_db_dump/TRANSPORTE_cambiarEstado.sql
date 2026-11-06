
-- ----------------------------------------------------------------------------
-- 5) cambiarEstado: el bloqueo de REALIZADO por paradas pendientes se evalua
--    por porcion cuando llega idSolicitudUnidad; ademas propaga EN_RUTA y
--    REALIZADO al traslado correspondiente
-- ----------------------------------------------------------------------------
CREATE PROCEDURE TRANSPORTE_cambiarEstado
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

    -- No se puede finalizar mientras queden paradas sin procesar.
    -- Con porcion: solo las paradas del traslado de ESA porcion bloquean.
    IF @estado = 'REALIZADO' AND EXISTS (
        SELECT 1 FROM TP_PARADA_DETALLE d
        JOIN TP_TRASLADO_PARADAS p ON p.idParada = d.idParada
        WHERE ((@idSolicitudUnidad IS NOT NULL AND d.idSolicitudUnidad = @idSolicitudUnidad)
            OR (@idSolicitudUnidad IS NULL AND d.idSolicitud = @id))
          AND p.estado IN ('PENDIENTE','EN_PARADA'))
    BEGIN RAISERROR('La solicitud aun tiene paradas sin procesar en la ruta', 16, 1); RETURN; END

    IF @idSolicitudUnidad IS NOT NULL
    BEGIN
        UPDATE TP_SOLICITUD_UNIDADES SET estado = @estado WHERE idSolicitudUnidad = @idSolicitudUnidad AND idSolicitud = @id;

        -- Propagar al traslado de la porcion (sin degradar un REALIZADO)
        UPDATE TP_TRASLADOS
        SET estado = CASE WHEN @estado = 'EN_RUTA' THEN 'EN_RUTA'
                          WHEN @estado = 'REALIZADO' THEN 'REALIZADO'
                          ELSE estado END
        WHERE idTraslado = (SELECT idTraslado FROM TP_SOLICITUD_UNIDADES WHERE idSolicitudUnidad = @idSolicitudUnidad)
          AND estado IN ('PENDIENTE','ASIGNADO','EN_RUTA');

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

        -- Propagar al traslado implicito/grupal de la solicitud
        UPDATE TP_TRASLADOS
        SET estado = CASE WHEN @estado = 'EN_RUTA' THEN 'EN_RUTA'
                          WHEN @estado = 'REALIZADO' THEN 'REALIZADO'
                          ELSE estado END
        WHERE idTraslado = (SELECT idTraslado FROM TP_SOLICITUDES WHERE idSolicitud = @id)
          AND estado IN ('PENDIENTE','ASIGNADO','EN_RUTA')
          AND (@estado <> 'REALIZADO'
               OR NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES sx
                              WHERE sx.idTraslado = (SELECT idTraslado FROM TP_SOLICITUDES WHERE idSolicitud = @id)
                                AND sx.idSolicitud <> @id AND sx.estado NOT IN ('REALIZADO','ANULADO')));
    END
    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES('SOLICITUD',@id,CONCAT('ESTADO_',@estado),JSON_VALUE(@json,'$.usuario'),@json);
    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT u.idUsuario, 'Estado de movilidad actualizado', CONCAT('La solicitud #',@id,' cambio a ',@estado), 'ESTADO'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario=s.usuarioRegistra WHERE s.idSolicitud=@id AND u.activo=1;
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END

