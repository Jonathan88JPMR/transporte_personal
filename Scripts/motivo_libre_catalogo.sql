-- =====================================================================
-- Motivo libre del supervisor -> se registra en el catalogo TP_MOTIVOS
--
-- La vista movil del supervisor permite escribir el motivo en vez de
-- elegirlo del catalogo. Este fix hace que TRANSPORTE_guardarSolicitud:
--
-- 1) Normalice el motivo con el formato de la lista actual
--    ("Primera mayuscula": Actividad, Salud, Capacitación, Emergencia),
--    asi la solicitud y los reportes porMotivo agrupan consistente.
-- 2) Inserte el motivo en TP_MOTIVOS si no existe ya (dedupe por
--    UPPER para no duplicar por mayusculas/minusculas).
-- =====================================================================
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_guardarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @usuario NVARCHAR(50) = JSON_VALUE(@json, '$.usuarioRegistra');
    DECLARE @idArea INT = (SELECT idArea FROM TP_USUARIOS WHERE usuario = @usuario);
    DECLARE @areaNombre NVARCHAR(100) = COALESCE(
        (SELECT nombre FROM TP_AREAS WHERE idArea = @idArea),
        JSON_VALUE(@json, '$.area'));
    DECLARE @prioridad NVARCHAR(15) = UPPER(COALESCE(NULLIF(JSON_VALUE(@json, '$.prioridad'), ''), 'NORMAL'));
    IF @prioridad NOT IN ('NORMAL', 'ALTA', 'EMERGENCIA') SET @prioridad = 'NORMAL';

    -- Motivo normalizado al formato del catalogo: trim + primera letra
    -- mayuscula y resto minuscula (ej. "  salud  " -> "Salud")
    DECLARE @motivo NVARCHAR(100) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@json, '$.motivo'))), '');
    IF @motivo IS NOT NULL
        SET @motivo = UPPER(LEFT(@motivo, 1)) + LOWER(SUBSTRING(@motivo, 2, LEN(@motivo)));

    -- Guarda: SPTRANS solo edita solicitudes de su area (o las que registro
    -- el si no tiene area). Crear no se restringe.
    IF @idSolicitud IS NOT NULL AND @idSolicitud <> 0
       AND EXISTS (SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS')
       AND NOT EXISTS (
           SELECT 1 FROM TP_SOLICITUDES s
           JOIN TP_USUARIOS u ON u.usuario = @usuario
           WHERE s.idSolicitud = @idSolicitud
             AND (s.idArea = u.idArea
                  OR (s.idArea IS NULL AND s.area = u.area)
                  OR (u.idArea IS NULL AND s.usuarioRegistra = @usuario)))
    BEGIN RAISERROR('Solo puede editar solicitudes de su propia area', 16, 1); RETURN; END

    IF @idSolicitud IS NULL OR @idSolicitud = 0
    BEGIN
        INSERT INTO TP_SOLICITUDES (nombre, area, idArea, fechaProgramada, horaProgramada, horaRequerida, puntoPartida, puntoLlegada,
                                    cantidad, motivo, observacion, prioridad, esEmergencia, usuarioRegistra)
        SELECT JSON_VALUE(@json, '$.nombre'), @areaNombre, @idArea,
               COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fechaProgramada') AS DATE), CAST(GETDATE() AS DATE)),
               -- Hora de digitacion: siempre la del servidor, no la que manda el cliente
               CONVERT(CHAR(5), GETDATE(), 108),
               -- Hora requerida: la que eligio el supervisor (fallback a la del cliente por compatibilidad)
               COALESCE(NULLIF(JSON_VALUE(@json, '$.horaRequerida'), ''), JSON_VALUE(@json, '$.horaProgramada')),
               JSON_VALUE(@json, '$.puntoPartida'),
               JSON_VALUE(@json, '$.puntoLlegada'), TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT),
               @motivo, JSON_VALUE(@json, '$.observacion'),
               @prioridad, COALESCE(TRY_CAST(JSON_VALUE(@json, '$.esEmergencia') AS BIT), 0), @usuario;
        SET @idSolicitud = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        -- Solo editable mientras el coordinador no la haya asignado
        IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud AND estado = 'PENDIENTE')
        BEGIN RAISERROR('Solo se pueden editar solicitudes pendientes de asignacion', 16, 1); RETURN; END

        UPDATE TP_SOLICITUDES
        SET fechaProgramada = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fechaProgramada') AS DATE), fechaProgramada),
            horaProgramada = JSON_VALUE(@json, '$.horaProgramada'),
            horaRequerida  = COALESCE(NULLIF(JSON_VALUE(@json, '$.horaRequerida'), ''), horaRequerida),
            puntoPartida   = JSON_VALUE(@json, '$.puntoPartida'),
            puntoLlegada   = JSON_VALUE(@json, '$.puntoLlegada'),
            cantidad       = TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT),
            motivo         = @motivo,
            observacion    = JSON_VALUE(@json, '$.observacion'),
            prioridad      = COALESCE(NULLIF(JSON_VALUE(@json, '$.prioridad'), ''), prioridad),
            esEmergencia   = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.esEmergencia') AS BIT), esEmergencia)
        WHERE idSolicitud = @idSolicitud;
    END

    -- Catalogo: registra el motivo si es nuevo (dedupe por UPPER;
    -- reactiva si existia pero estaba desactivado)
    IF @motivo IS NOT NULL
    BEGIN
        IF EXISTS (SELECT 1 FROM TP_MOTIVOS WHERE UPPER(nombre) = UPPER(@motivo))
            UPDATE TP_MOTIVOS SET activo = 1 WHERE UPPER(nombre) = UPPER(@motivo) AND activo = 0;
        ELSE
            INSERT INTO TP_MOTIVOS (nombre) VALUES (@motivo);
    END

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('SOLICITUD',@idSolicitud,CASE WHEN JSON_VALUE(@json,'$.idSolicitud') IS NULL THEN 'CREAR' ELSE 'EDITAR' END,JSON_VALUE(@json,'$.usuarioRegistra'),@json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO
