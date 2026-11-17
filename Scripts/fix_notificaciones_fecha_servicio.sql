-- =====================================================================
-- Fix: TP_NOTIFICACIONES.fechaServicio
--
-- Las alertas de asignacion del conductor deben dispararse solo cuando el
-- servicio es del dia actual. La notificacion necesita conocer la
-- fechaProgramada del servicio, por eso se agrega la columna fechaServicio.
--
-- Aplicacion:
--   1) Ejecutar este script (agrega la columna y actualiza
--      TRANSPORTE_listarNotificaciones para devolverla).
--   2) Re-ejecutar Scripts/cupo_flexible.sql: los SP *_V2 ya graban
--      fechaServicio en las notificaciones ASIGNACION.
--
-- Las notificaciones anteriores al cambio quedan con fechaServicio NULL:
-- el frontend las trata como "no son de hoy" y ya no disparan alerta.
-- =====================================================================
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('TP_NOTIFICACIONES') AND name = 'fechaServicio')
    ALTER TABLE TP_NOTIFICACIONES ADD fechaServicio DATE NULL;
GO

CREATE OR ALTER PROCEDURE TRANSPORTE_listarNotificaciones @json NVARCHAR(MAX)
AS BEGIN
    DECLARE @idUsuario INT = TRY_CAST(JSON_VALUE(@json, '$.idUsuario') AS INT);
    SELECT TOP 100 idNotificacion, titulo, mensaje, tipo, leida, fecha, fechaServicio FROM TP_NOTIFICACIONES
    WHERE idUsuario = @idUsuario OR idUsuario IS NULL ORDER BY fecha DESC FOR JSON PATH;
END
GO
