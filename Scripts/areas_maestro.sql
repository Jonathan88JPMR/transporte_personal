-- =====================================================================
-- Maestro de AREAS (aplicado 2026-10-06)
-- 1) Tabla TP_AREAS + columnas idArea en TP_USUARIOS / TP_SOLICITUDES
-- 2) Backfill y normalizacion del texto "area"
-- 3) administrarCatalogo: entidad AREA + usuarios con idArea
-- 4) guardarSolicitud: el area se hereda del usuario que registra
-- 5) listarSolicitudes: supervisor (SPTRANS) solo ve su area
-- 6) login/reportes devuelven el nombre del area desde el maestro
-- =====================================================================

-- 1) Tabla maestra
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'TP_AREAS')
BEGIN
    CREATE TABLE TP_AREAS (
        idArea INT IDENTITY(1,1) PRIMARY KEY,
        nombre NVARCHAR(100) NOT NULL,
        activo BIT NOT NULL DEFAULT 1
    );
END
GO

-- Semillas: areas existentes en usuarios y solicitudes (normalizadas)
INSERT INTO TP_AREAS (nombre)
SELECT DISTINCT LTRIM(RTRIM(u.area))
FROM TP_USUARIOS u
WHERE u.area IS NOT NULL AND LTRIM(RTRIM(u.area)) <> ''
  AND NOT EXISTS (SELECT 1 FROM TP_AREAS a WHERE UPPER(a.nombre) = UPPER(LTRIM(RTRIM(u.area))));

INSERT INTO TP_AREAS (nombre)
SELECT DISTINCT LTRIM(RTRIM(s.area))
FROM TP_SOLICITUDES s
WHERE s.area IS NOT NULL AND LTRIM(RTRIM(s.area)) <> ''
  AND NOT EXISTS (SELECT 1 FROM TP_AREAS a WHERE UPPER(a.nombre) = UPPER(LTRIM(RTRIM(s.area))));
GO

-- 2) Columnas idArea
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('TP_USUARIOS') AND name = 'idArea')
    ALTER TABLE TP_USUARIOS ADD idArea INT NULL REFERENCES TP_AREAS(idArea);
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('TP_SOLICITUDES') AND name = 'idArea')
    ALTER TABLE TP_SOLICITUDES ADD idArea INT NULL REFERENCES TP_AREAS(idArea);
GO

-- Backfill + normalizacion del texto (join insensible a mayusculas)
UPDATE u SET u.idArea = a.idArea
FROM TP_USUARIOS u JOIN TP_AREAS a ON UPPER(a.nombre) = UPPER(LTRIM(RTRIM(u.area)))
WHERE u.idArea IS NULL;
UPDATE u SET u.area = a.nombre FROM TP_USUARIOS u JOIN TP_AREAS a ON a.idArea = u.idArea;

UPDATE s SET s.idArea = a.idArea
FROM TP_SOLICITUDES s JOIN TP_AREAS a ON UPPER(a.nombre) = UPPER(LTRIM(RTRIM(s.area)))
WHERE s.idArea IS NULL;
UPDATE s SET s.area = a.nombre FROM TP_SOLICITUDES s JOIN TP_AREAS a ON a.idArea = s.idArea;
GO

-- 3) Administrar catalogo: entidad AREA + usuario con idArea (area texto sincronizado)
CREATE OR ALTER PROCEDURE TRANSPORTE_administrarCatalogo
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entidad NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.entidad'));
    DECLARE @accion NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.accion'));
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.id') AS INT);
    IF @accion <> 'LISTAR' INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES(@entidad,@id,@accion,JSON_VALUE(@json,'$.usuario'),@json);
    IF @entidad = 'PUNTO'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_PUNTOS(nombre, latitud, longitud) VALUES(JSON_VALUE(@json, '$.nombre'), TRY_CAST(JSON_VALUE(@json, '$.latitud') AS DECIMAL(9,6)), TRY_CAST(JSON_VALUE(@json, '$.longitud') AS DECIMAL(9,6)));
            ELSE UPDATE TP_PUNTOS SET nombre = JSON_VALUE(@json, '$.nombre'), latitud = TRY_CAST(JSON_VALUE(@json, '$.latitud') AS DECIMAL(9,6)), longitud = TRY_CAST(JSON_VALUE(@json, '$.longitud') AS DECIMAL(9,6)), activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo) WHERE idPunto = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_PUNTOS SET activo = 0 WHERE idPunto = @id;
        SELECT idPunto, nombre, latitud, longitud, activo FROM TP_PUNTOS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    IF @entidad = 'MOTIVO'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_MOTIVOS(nombre) VALUES(JSON_VALUE(@json, '$.nombre'));
            ELSE UPDATE TP_MOTIVOS SET nombre = JSON_VALUE(@json, '$.nombre'), activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo) WHERE idMotivo = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_MOTIVOS SET activo = 0 WHERE idMotivo = @id;
        SELECT idMotivo, nombre, activo FROM TP_MOTIVOS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    IF @entidad = 'AREA'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_AREAS(nombre) VALUES(JSON_VALUE(@json, '$.nombre'));
            ELSE UPDATE TP_AREAS SET nombre = JSON_VALUE(@json, '$.nombre'), activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo) WHERE idArea = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_AREAS SET activo = 0 WHERE idArea = @id;
        SELECT idArea, nombre, activo FROM TP_AREAS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    IF @entidad = 'UNIDAD'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_UNIDADES(placa, capacidad) VALUES(JSON_VALUE(@json, '$.placa'), TRY_CAST(JSON_VALUE(@json, '$.capacidad') AS INT));
            ELSE UPDATE TP_UNIDADES SET placa = JSON_VALUE(@json, '$.placa'), capacidad = TRY_CAST(JSON_VALUE(@json, '$.capacidad') AS INT), activa = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activa) WHERE idUnidad = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_UNIDADES SET activa = 0 WHERE idUnidad = @id;
        SELECT idUnidad, placa, capacidad, activa AS activo FROM TP_UNIDADES ORDER BY placa FOR JSON PATH; RETURN;
    END
    IF @entidad = 'USUARIO'
    BEGIN
        DECLARE @idArea INT = TRY_CAST(JSON_VALUE(@json, '$.idArea') AS INT);
        DECLARE @areaNombre NVARCHAR(100) = COALESCE(
            (SELECT nombre FROM TP_AREAS WHERE idArea = @idArea),
            JSON_VALUE(@json, '$.area'));
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_USUARIOS(usuario, claveHash, nombre, idrol, placa, area, idArea)
                VALUES(JSON_VALUE(@json, '$.usuario'), JSON_VALUE(@json, '$.claveHash'),
                       JSON_VALUE(@json, '$.nombre'), JSON_VALUE(@json, '$.idrol'), JSON_VALUE(@json, '$.placa'), @areaNombre, @idArea);
            ELSE UPDATE TP_USUARIOS SET nombre = JSON_VALUE(@json, '$.nombre'), idrol = JSON_VALUE(@json, '$.idrol'),
                 placa = JSON_VALUE(@json, '$.placa'), area = @areaNombre, idArea = @idArea,
                 activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo),
                 claveHash = COALESCE(NULLIF(JSON_VALUE(@json, '$.claveHash'), ''), claveHash)
                 WHERE idUsuario = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_USUARIOS SET activo = 0 WHERE idUsuario = @id;
        SELECT idUsuario, usuario, nombre, idrol, placa, area, idArea, activo FROM TP_USUARIOS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    RAISERROR(N'Entidad administrativa invalida', 16, 1);
END
GO

-- 4) Guardar solicitud: el area se hereda del usuario que registra
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

    IF @idSolicitud IS NULL OR @idSolicitud = 0
    BEGIN
        INSERT INTO TP_SOLICITUDES (nombre, area, idArea, fechaProgramada, horaProgramada, puntoPartida, puntoLlegada,
                                    cantidad, motivo, observacion, esEmergencia, usuarioRegistra)
        SELECT JSON_VALUE(@json, '$.nombre'), @areaNombre, @idArea,
               COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fechaProgramada') AS DATE), CAST(GETDATE() AS DATE)),
               JSON_VALUE(@json, '$.horaProgramada'), JSON_VALUE(@json, '$.puntoPartida'),
               JSON_VALUE(@json, '$.puntoLlegada'), TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT),
               JSON_VALUE(@json, '$.motivo'), JSON_VALUE(@json, '$.observacion'),
               COALESCE(TRY_CAST(JSON_VALUE(@json, '$.esEmergencia') AS BIT), 0), @usuario;
        SET @idSolicitud = SCOPE_IDENTITY();
    END
    ELSE
    BEGIN
        UPDATE TP_SOLICITUDES
        SET fechaProgramada = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fechaProgramada') AS DATE), fechaProgramada),
            horaProgramada = JSON_VALUE(@json, '$.horaProgramada'),
            puntoPartida   = JSON_VALUE(@json, '$.puntoPartida'),
            puntoLlegada   = JSON_VALUE(@json, '$.puntoLlegada'),
            cantidad       = TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT),
            motivo         = JSON_VALUE(@json, '$.motivo'),
            observacion    = JSON_VALUE(@json, '$.observacion'),
            esEmergencia   = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.esEmergencia') AS BIT), esEmergencia)
        WHERE idSolicitud = @idSolicitud;
    END

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('SOLICITUD',@idSolicitud,CASE WHEN JSON_VALUE(@json,'$.idSolicitud') IS NULL THEN 'CREAR' ELSE 'EDITAR' END,JSON_VALUE(@json,'$.usuarioRegistra'),@json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

-- 5) Listar solicitudes: supervisor solo ve las de su area
CREATE OR ALTER PROCEDURE TRANSPORTE_listarSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha  DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);
    DECLARE @estado NVARCHAR(20) = JSON_VALUE(@json, '$.estado');
    DECLARE @usuario NVARCHAR(50) = JSON_VALUE(@json, '$.usuario');
    -- Si quien consulta es supervisor, solo ve solicitudes de su area
    DECLARE @idAreaFiltro INT = (SELECT idArea FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS');

    SELECT s.idSolicitud, s.idTraslado, s.idArea, s.nombre, COALESCE(a.nombre, s.area) AS area,
           s.fechaProgramada, s.horaProgramada, s.puntoPartida, s.puntoLlegada, s.cantidad,
           s.motivo, s.observacion, s.esEmergencia, s.placa,
           s.realizado, s.estado, s.usuarioRegistra, s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
    WHERE (@fecha  IS NULL OR s.fechaProgramada = @fecha)
      AND (@estado IS NULL OR s.estado = @estado)
      AND (@usuario IS NULL OR @idAreaFiltro IS NULL OR s.idArea = @idAreaFiltro)
    -- RN-004: primero en llegar, primero en ser atendido (emergencias siempre al tope)
    ORDER BY s.esEmergencia DESC, s.fechaRegistro, s.idSolicitud
    FOR JSON PATH;
END
GO

-- 6a) Login: devuelve idArea
CREATE OR ALTER PROCEDURE TRANSPORTE_login
    @usuario   NVARCHAR(50),
    @claveHash NVARCHAR(200)
AS
BEGIN
    SELECT u.idUsuario, u.usuario, u.nombre, u.idrol,
           CASE u.idrol
               WHEN 'SPTRANS' THEN 'SUPERVISOR'
               WHEN 'COTRANS' THEN 'COORDINADOR'
               WHEN 'CHTRANS' THEN 'CONDUCTOR'
               WHEN 'ADTRANS' THEN 'ADMINISTRADOR'
               ELSE u.idrol
           END AS rol,
           u.placa, u.area, u.idArea, u.claveHash
    FROM TP_USUARIOS u
    WHERE u.usuario = @usuario AND u.activo = 1;
END
GO

-- 6b) Reporte solicitudes: area desde el maestro
CREATE OR ALTER PROCEDURE TRANSPORTE_reporteSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @desde DATE = TRY_CAST(JSON_VALUE(@json, '$.desde') AS DATE);
    DECLARE @hasta DATE = TRY_CAST(JSON_VALUE(@json, '$.hasta') AS DATE);

    SELECT s.idSolicitud, s.idTraslado, s.idArea, s.nombre, s.usuarioRegistra, COALESCE(a.nombre, s.area) AS area,
           s.fechaProgramada, s.horaProgramada, s.puntoPartida, s.puntoLlegada, s.cantidad,
           s.motivo, s.observacion, s.esEmergencia, s.placa, s.realizado, s.estado,
           s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
    WHERE (@desde IS NULL OR s.fechaProgramada >= @desde)
      AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
      AND s.estado <> 'ANULADO'
    ORDER BY s.fechaRegistro DESC
    FOR JSON PATH;
END
GO

-- 6c) Indicadores: areas agrupadas por el maestro
CREATE OR ALTER PROCEDURE TRANSPORTE_reporteIndicadores
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @desde DATE = TRY_CAST(JSON_VALUE(@json, '$.desde') AS DATE);
    DECLARE @hasta DATE = TRY_CAST(JSON_VALUE(@json, '$.hasta') AS DATE);
    SELECT
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalSolicitudes,
      (SELECT COALESCE(SUM(cantidad),0) FROM TP_SOLICITUDES WHERE estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalPersonas,
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE estado = 'REALIZADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalRealizados,
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE esEmergencia = 1 AND estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalEmergencias,
      (SELECT COALESCE(AVG(CAST(DATEDIFF(MINUTE,fechaInicio,fechaFin) AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND fechaFin IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) tiempoPromedioMinutos,
      (SELECT COALESCE(AVG(CAST(CASE WHEN DATEDIFF(MINUTE,fechaRegistro,fechaInicio)<0 THEN 0 ELSE DATEDIFF(MINUTE,fechaRegistro,fechaInicio) END AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) esperaPromedioMinutos,
      (SELECT COALESCE(100.0*SUM(CASE WHEN ABS(DATEDIFF(MINUTE,DATEADD(MINUTE,DATEDIFF(MINUTE,0,TRY_CAST(horaProgramada AS TIME)),CAST(fechaProgramada AS DATETIME)),fechaInicio))<=10 THEN 1 ELSE 0 END)/NULLIF(COUNT(*),0),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) puntualidadPorcentaje,
      JSON_QUERY((SELECT s.placa, COUNT(*) viajes, SUM(s.cantidad) personas,
                         CAST(100.0 * SUM(s.cantidad) / NULLIF(COUNT(*) * MAX(u.capacidad), 0) AS DECIMAL(6,2)) ocupacionPorcentaje
                  FROM TP_SOLICITUDES s LEFT JOIN TP_UNIDADES u ON u.placa = s.placa
                  WHERE s.estado <> 'ANULADO' AND s.placa IS NOT NULL AND s.placa <> 'MULTIPLE'
                    AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  GROUP BY s.placa FOR JSON PATH)) unidades,
      JSON_QUERY((SELECT COALESCE(a.nombre, s.area) AS area, COUNT(*) solicitudes, SUM(s.cantidad) personas
                  FROM TP_SOLICITUDES s LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
                  WHERE s.estado <> 'ANULADO' AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  GROUP BY COALESCE(a.nombre, s.area) FOR JSON PATH)) areas,
      JSON_QUERY((SELECT u.nombre conductor, u.placa, COUNT(s.idSolicitud) servicios, COALESCE(SUM(s.cantidad),0) personas
                  FROM TP_USUARIOS u LEFT JOIN TP_SOLICITUDES s ON s.placa=u.placa AND s.estado='REALIZADO'
                    AND (@desde IS NULL OR s.fechaProgramada>=@desde) AND (@hasta IS NULL OR s.fechaProgramada<=@hasta)
                  WHERE u.idrol='CHTRANS' AND u.activo=1 GROUP BY u.nombre,u.placa FOR JSON PATH)) conductores
    FOR JSON PATH;
END
GO
