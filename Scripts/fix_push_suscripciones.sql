-- =====================================================================
-- Fix: Web Push — tabla de suscripciones y SPs asociados
--
-- Nivel 2 de alertas al conductor: notificaciones push reales (service
-- worker) aunque la app este cerrada o la pantalla apagada.
--
-- Cada dispositivo del usuario registra una suscripcion (endpoint +
-- claves p256dh/auth). El API envia push a las suscripciones de los
-- usuarios cuya placa recibio una asignacion.
--
-- Aplicar despues de fix_notificaciones_fecha_servicio.sql.
-- =====================================================================
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

IF NOT EXISTS (SELECT 1 FROM sys.objects WHERE object_id = OBJECT_ID(N'TP_PUSH_SUSCRIPCIONES'))
CREATE TABLE TP_PUSH_SUSCRIPCIONES (
    idSuscripcion BIGINT IDENTITY(1,1) PRIMARY KEY,
    idUsuario INT NOT NULL REFERENCES TP_USUARIOS(idUsuario),
    endpoint NVARCHAR(500) NOT NULL,
    p256dh NVARCHAR(200) NOT NULL,
    auth NVARCHAR(100) NOT NULL,
    fecha DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UX_TP_PUSH_ENDPOINT')
    CREATE UNIQUE INDEX UX_TP_PUSH_ENDPOINT ON TP_PUSH_SUSCRIPCIONES(endpoint);
GO

-- Guardar/actualizar suscripcion  @json: { "idUsuario": 1, "endpoint": "...", "p256dh": "...", "auth": "..." }
CREATE OR ALTER PROCEDURE TRANSPORTE_guardarSuscripcionPush @json NVARCHAR(MAX)
AS BEGIN
    SET NOCOUNT ON;
    DECLARE @idUsuario INT = TRY_CAST(JSON_VALUE(@json, '$.idUsuario') AS INT);
    DECLARE @endpoint NVARCHAR(500) = JSON_VALUE(@json, '$.endpoint');
    DECLARE @p256dh NVARCHAR(200) = JSON_VALUE(@json, '$.p256dh');
    DECLARE @auth NVARCHAR(100) = JSON_VALUE(@json, '$.auth');
    IF @idUsuario IS NULL OR @endpoint IS NULL OR @p256dh IS NULL OR @auth IS NULL
    BEGIN RAISERROR('Suscripcion incompleta', 16, 1); RETURN; END

    -- El endpoint es del dispositivo: si ya existe se reasigna al usuario
    -- actual (relogin con otra cuenta) y se actualizan las claves.
    IF EXISTS (SELECT 1 FROM TP_PUSH_SUSCRIPCIONES WHERE endpoint = @endpoint)
        UPDATE TP_PUSH_SUSCRIPCIONES
        SET idUsuario = @idUsuario, p256dh = @p256dh, auth = @auth, fecha = SYSUTCDATETIME()
        WHERE endpoint = @endpoint;
    ELSE
        INSERT INTO TP_PUSH_SUSCRIPCIONES(idUsuario, endpoint, p256dh, auth)
        VALUES (@idUsuario, @endpoint, @p256dh, @auth);

    SELECT idSuscripcion, idUsuario, endpoint, fecha FROM TP_PUSH_SUSCRIPCIONES
    WHERE endpoint = @endpoint FOR JSON PATH;
END
GO

-- Dar de baja suscripcion (logout o endpoint muerto)
-- @json: { "endpoint": "..." }
CREATE OR ALTER PROCEDURE TRANSPORTE_eliminarSuscripcionPush @json NVARCHAR(MAX)
AS BEGIN
    SET NOCOUNT ON;
    DECLARE @endpoint NVARCHAR(500) = JSON_VALUE(@json, '$.endpoint');
    DELETE FROM TP_PUSH_SUSCRIPCIONES WHERE endpoint = @endpoint;
    SELECT @@ROWCOUNT AS eliminadas FOR JSON PATH;
END
GO
