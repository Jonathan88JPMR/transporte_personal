-- =====================================================================
-- SPs V2: nuevo estado A_BORDO + cierre automatico de paradas al finalizar
--
-- Los SPs originales NO se modifican: se crean versiones *_V2 y el API
-- las invoca a traves de TransporteRepositoryImpl. Los originales quedan
-- intactos por si hay que volver atras.
--
-- Cadena de estados: ASIGNADO -> EN_RUTA -> A_BORDO -> REALIZADO
-- El conductor marca "Iniciar recojo" (EN_RUTA), "Recojo" (A_BORDO:
-- personal a bordo = cuadro amarillo del coordinador) y "Dejar personal"
-- (REALIZADO). Antes el amarillo solo se derivaba del detalle de paradas,
-- asi que los servicios sin paradas saltaban de rojo a verde.
--
-- 1) TRANSPORTE_cambiarEstado_V2: acepta A_BORDO; al pasar a REALIZADO
--    cierra automaticamente las paradas pendientes del servicio con sus
--    cantidades planeadas (flujo "Dejar personal" en un toque). Conserva
--    de la version viva: validacion por porcion, bloqueo de estados,
--    propagacion a TP_TRASLADOS y auditoria/notificacion.
-- 2) TRANSPORTE_listarUnidades_V2: el cupo ocupado incluye A_BORDO
--    (la gente esta fisicamente a bordo, el asiento sigue ocupado)
-- 3) TRANSPORTE_listarServiciosConductor_V2: las paradas ahora traen
--    idParada, estado, conteos reales y detalle por solicitud (el
--    checklist del conductor y el aviso de "paradas por procesar"
--    funcionan con datos reales). Ademas usa el traslado de la porcion
--    en servicios MULTIPLE (su.idTraslado).
-- =====================================================================

-- 1) Cambiar estado V2: A_BORDO + auto-cierre de paradas al realizar
CREATE PROCEDURE TRANSPORTE_cambiarEstado_V2
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idSolicitudUnidad INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitudUnidad') AS INT);
    DECLARE @estado NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.estado'));

    IF @estado NOT IN ('ASIGNADO', 'EN_RUTA', 'A_BORDO', 'REALIZADO')
    BEGIN RAISERROR(N'Estado de solicitud invalido', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND estado <> 'ANULADO')
    BEGIN RAISERROR('La solicitud no existe o esta anulada', 16, 1); RETURN; END

    IF @idSolicitudUnidad IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitudUnidad = @idSolicitudUnidad AND idSolicitud = @id AND estado <> 'ANULADO')
    BEGIN RAISERROR('La porcion de unidad no existe o esta anulada', 16, 1); RETURN; END

    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND placa IS NOT NULL)
    BEGIN RAISERROR('La solicitud debe tener una unidad asignada', 16, 1); RETURN; END

    -- Cierre automatico de paradas al finalizar: las paradas pendientes del
    -- servicio se registran con sus cantidades planeadas. El conductor ya
    -- confirmo "Dejar personal" en la app, asi que el flujo de 3 pasos no
    -- exige pasar por el checklist cuando el servicio es simple. Cada
    -- parada genera su asiento de auditoria (accion CIERRE_AUTOMATICO).
    IF @estado = 'REALIZADO'
    BEGIN
        DECLARE @cerradas TABLE (idParada INT);

        UPDATE p
        SET estado = 'REALIZADA',
            subieronReal = COALESCE(p.cantidadSube, 0),
            bajaronReal  = COALESCE(p.cantidadBaja, 0),
            horaLlegada  = COALESCE(p.horaLlegada, GETDATE()),
            horaSalida   = GETDATE(),
            usuarioRegistra = JSON_VALUE(@json, '$.usuario'),
            fechaRegistro    = GETDATE()
        OUTPUT inserted.idParada INTO @cerradas
        FROM TP_TRASLADO_PARADAS p
        WHERE p.estado IN ('PENDIENTE','EN_PARADA')
          AND EXISTS (SELECT 1 FROM TP_PARADA_DETALLE d
                      WHERE d.idParada = p.idParada
                        AND ((@idSolicitudUnidad IS NOT NULL AND d.idSolicitudUnidad = @idSolicitudUnidad)
                             OR (@idSolicitudUnidad IS NULL AND d.idSolicitud = @id)));

        -- Conteo real por solicitud: se asume lo planeado en la parada
        UPDATE d SET d.cantidadReal = d.cantidadPlaneada
        FROM TP_PARADA_DETALLE d
        JOIN @cerradas c ON c.idParada = d.idParada;

        INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
        SELECT 'PARADA', c.idParada, 'CIERRE_AUTOMATICO', JSON_VALUE(@json,'$.usuario'), @json
        FROM @cerradas c;
    END

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
                          WHEN EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado = 'EN_RUTA') THEN 'EN_RUTA'
                          WHEN EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado = 'A_BORDO') THEN 'A_BORDO'
                          ELSE 'ASIGNADO' END,
            realizado = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO' AND estado <> 'ANULADO') THEN 1 ELSE 0 END,
            fechaInicio = CASE WHEN @estado IN ('EN_RUTA','A_BORDO') AND fechaInicio IS NULL THEN GETDATE() ELSE fechaInicio END,
            fechaFin = CASE WHEN NOT EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'REALIZADO' AND estado <> 'ANULADO') THEN GETDATE() ELSE fechaFin END
        WHERE idSolicitud = @id;
    END
    ELSE
    BEGIN
        UPDATE TP_SOLICITUDES
        SET estado = @estado,
            realizado = CASE WHEN @estado = 'REALIZADO' THEN 1 ELSE 0 END,
            fechaInicio = CASE WHEN @estado IN ('EN_RUTA','A_BORDO') AND fechaInicio IS NULL THEN GETDATE() ELSE fechaInicio END,
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
GO

-- 2) Listar unidades V2: el cupo ocupado cuenta servicios A_BORDO
CREATE PROCEDURE TRANSPORTE_listarUnidades_V2 @json NVARCHAR(MAX)
AS BEGIN
    DECLARE @fecha DATE = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE), CAST(GETDATE() AS DATE));

    SELECT u.idUnidad, u.placa, u.capacidad,
           CASE WHEN EXISTS (SELECT 1 FROM TP_SOLICITUDES s
                             WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                               AND s.estado IN ('ASIGNADO', 'EN_RUTA', 'A_BORDO'))
                OR EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES su
                           JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                           WHERE su.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                             AND su.estado IN ('ASIGNADO', 'EN_RUTA', 'A_BORDO') AND s2.estado <> 'ANULADO')
                THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS disponible,
           u.capacidad
             - COALESCE((SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
                         WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                           AND s.estado IN ('ASIGNADO', 'EN_RUTA', 'A_BORDO')), 0)
             - COALESCE((SELECT SUM(su.cantidadAsignada) FROM TP_SOLICITUD_UNIDADES su
                         JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                         WHERE su.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                           AND su.estado IN ('ASIGNADO', 'EN_RUTA', 'A_BORDO') AND s2.estado <> 'ANULADO'), 0)
               AS cupoDisponible
    FROM TP_UNIDADES u WHERE u.activa = 1 ORDER BY u.placa FOR JSON PATH;
END
GO

-- 3) Servicios del conductor V2: paradas con idParada, estado, conteos
--    reales y detalle por solicitud; en MULTIPLE usa el traslado de la
--    porcion (su.idTraslado) para que cada unidad vea su propia ruta.
CREATE PROCEDURE TRANSPORTE_listarServiciosConductor_V2
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @fecha DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);

    SELECT s.idSolicitud, s.idTraslado, su.idSolicitudUnidad, s.nombre, s.area, s.fechaProgramada, s.horaProgramada, s.horaRequerida,
           s.puntoPartida, s.puntoLlegada, COALESCE(su.cantidadAsignada,s.cantidad) cantidad, s.motivo, s.observacion,
           CASE WHEN COALESCE(su.esEmergencia, 0) = 1 THEN 'EMERGENCIA' ELSE s.prioridad END AS prioridad,
           CASE WHEN COALESCE(su.esEmergencia, 0) = 1 OR s.esEmergencia = 1 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS esEmergencia,
           @placa placa,
           CASE WHEN su.idSolicitudUnidad IS NULL THEN s.realizado ELSE CASE WHEN su.estado='REALIZADO' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END END realizado,
           COALESCE(su.estado,s.estado) estado, s.fechaInicio, s.fechaFin,
           t.ruta,
           -- Paradas del traslado (de la porcion si existe) con estado real
           -- y detalle por solicitud para el checklist del conductor
           JSON_QUERY((SELECT p.idParada, p.punto, p.orden, p.cantidadSube, p.cantidadBaja,
                   p.subieronReal, p.bajaronReal, p.estado,
                   JSON_QUERY((SELECT d.idParadaDetalle, d.idSolicitud, d.idSolicitudUnidad,
                               d.tipo, d.cantidadPlaneada, d.cantidadReal
                        FROM TP_PARADA_DETALLE d WHERE d.idParada = p.idParada
                        FOR JSON PATH)) AS detalle
            FROM TP_TRASLADO_PARADAS p
            WHERE p.idTraslado = COALESCE(su.idTraslado, s.idTraslado)
            ORDER BY p.orden FOR JSON PATH)) AS paradas
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_SOLICITUD_UNIDADES su ON su.idSolicitud=s.idSolicitud
    LEFT JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad
    LEFT JOIN TP_TRASLADOS t ON t.idTraslado = COALESCE(su.idTraslado, s.idTraslado)
    WHERE (s.placa = @placa OR u.placa = @placa)
      AND s.estado <> 'ANULADO'
      AND (@fecha IS NULL OR s.fechaProgramada = @fecha)
    ORDER BY CASE WHEN COALESCE(su.esEmergencia,0)=1 OR s.prioridad='EMERGENCIA' THEN 0
                  WHEN s.prioridad='ALTA' THEN 1 ELSE 2 END,
             COALESCE(s.horaRequerida, s.horaProgramada), s.idSolicitud
    FOR JSON PATH;
END
GO
