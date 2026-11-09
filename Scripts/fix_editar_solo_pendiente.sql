-- =====================================================================
-- Fix: editar/anular solo mientras la solicitud no este asignada
--
-- La UI ya oculta Editar cuando estado <> 'PENDIENTE' y Anular cuando
-- estado no es PENDIENTE/ASIGNADO, pero los SPs no lo validaban: una
-- llamada directa al API podia editar o anular solicitudes ASIGNADO,
-- EN_RUTA, A_BORDO o REALIZADO (desincronizando paradas y cupo).
--
-- 1) TRANSPORTE_guardarSolicitud: el UPDATE solo aplica si la solicitud
--    sigue PENDIENTE (sin asignar por el coordinador).
-- 2) TRANSPORTE_eliminarSolicitud: solo permite anular PENDIENTE o
--    ASIGNADO (igual que la UI).
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
               JSON_VALUE(@json, '$.motivo'), JSON_VALUE(@json, '$.observacion'),
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
            motivo         = JSON_VALUE(@json, '$.motivo'),
            observacion    = JSON_VALUE(@json, '$.observacion'),
            prioridad      = COALESCE(NULLIF(JSON_VALUE(@json, '$.prioridad'), ''), prioridad),
            esEmergencia   = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.esEmergencia') AS BIT), esEmergencia)
        WHERE idSolicitud = @idSolicitud;
    END

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('SOLICITUD',@idSolicitud,CASE WHEN JSON_VALUE(@json,'$.idSolicitud') IS NULL THEN 'CREAR' ELSE 'EDITAR' END,JSON_VALUE(@json,'$.usuarioRegistra'),@json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_eliminarSolicitud
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @usuario NVARCHAR(50) = JSON_VALUE(@json, '$.usuario');

    IF EXISTS (SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS')
       AND NOT EXISTS (
           SELECT 1 FROM TP_SOLICITUDES s
           JOIN TP_USUARIOS u ON u.usuario = @usuario
           WHERE s.idSolicitud = @id
             AND (s.idArea = u.idArea
                  OR (s.idArea IS NULL AND s.area = u.area)
                  OR (u.idArea IS NULL AND s.usuarioRegistra = @usuario)))
    BEGIN RAISERROR('Solo puede anular solicitudes de su propia area', 16, 1); RETURN; END

    -- Solo anulable mientras no este en ejecucion ni terminada (igual que la UI)
    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND estado IN ('PENDIENTE','ASIGNADO'))
    BEGIN RAISERROR('Solo se pueden anular solicitudes pendientes o asignadas', 16, 1); RETURN; END

    UPDATE TP_SOLICITUDES SET estado = 'ANULADO' WHERE idSolicitud = @id;
    UPDATE TP_SOLICITUD_UNIDADES SET estado = 'ANULADO' WHERE idSolicitud = @id;

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES('SOLICITUD',@id,'ANULAR',JSON_VALUE(@json,'$.usuario'),@json);

    SELECT @id AS idSolicitud, 'ANULADO' AS estado FOR JSON PATH;
END
GO
