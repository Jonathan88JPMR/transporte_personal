-- =====================================================================
-- Clave visible cifrada (aplicar una sola vez)
--
-- Permite que admin/coordinador VEAN la clave actual de los usuarios en
-- el mantenedor. La clave se guarda CIFRADA con AES-GCM (la cifra el API,
-- nunca llega texto plano a la BD) en TP_USUARIOS.claveVisible; el login
-- sigue usando claveHash (PBKDF2) — la columna nueva es solo lectura
-- administrativa.
--
-- Usuarios existentes: claveVisible queda NULL (el hash no es
-- reversible); se llena la proxima vez que se les cree/cambie la clave.
--
-- NOTA: esta version del SP parte de la definicion VIVA en la BD
-- (extraida con sp_helptext el 2026-11-11): incluye TIPO_VEHICULO, CECO,
-- TRANSPORTISTA, TARIFA, UNIDAD enriquecida, dni y borrado logico.
-- Solo se toco el bloque USUARIO (+ columna en LISTAR).
-- =====================================================================

-- 1) Columna para la clave cifrada (contenido: base64 nonce|tag|cipher)
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('TP_USUARIOS') AND name = 'claveVisible')
    ALTER TABLE TP_USUARIOS ADD claveVisible NVARCHAR(300) NULL;
GO

SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 2) administrarCatalogo: version viva + claveVisible en USUARIO
CREATE OR ALTER PROCEDURE TRANSPORTE_administrarCatalogo
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @entidad NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.entidad'));
    DECLARE @accion NVARCHAR(20) = UPPER(JSON_VALUE(@json, '$.accion'));
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.id') AS INT);
    DECLARE @actor NVARCHAR(50) = COALESCE(JSON_VALUE(@json, '$.actor'), JSON_VALUE(@json, '$.usuario'));
    IF @accion <> 'LISTAR' INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES(@entidad,@id,@accion,@actor,@json);
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
    -- Catalogo de tipos de vehiculo (select del mantenedor de unidades)
    IF @entidad = 'TIPO_VEHICULO'
    BEGIN
        IF @accion = 'GUARDAR'
        BEGIN
            IF JSON_VALUE(@json, '$.nombre') IS NULL
            BEGIN RAISERROR(N'El nombre del tipo es obligatorio',16,1); RETURN; END
            IF @id IS NULL AND EXISTS(SELECT 1 FROM TP_TIPOS_VEHICULO WHERE nombre = JSON_VALUE(@json, '$.nombre'))
            BEGIN RAISERROR(N'Ya existe un tipo de vehiculo con ese nombre',16,1); RETURN; END
            IF @id IS NULL INSERT INTO TP_TIPOS_VEHICULO(nombre) VALUES(JSON_VALUE(@json, '$.nombre'));
            ELSE UPDATE TP_TIPOS_VEHICULO SET nombre = JSON_VALUE(@json, '$.nombre'),
                 activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo) WHERE idTipoVehiculo = @id;
        END
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_TIPOS_VEHICULO SET activo = 0 WHERE idTipoVehiculo = @id;
        SELECT idTipoVehiculo, nombre, activo FROM TP_TIPOS_VEHICULO ORDER BY nombre FOR JSON PATH; RETURN;
    END
    IF @entidad = 'AREA'
    BEGIN
        IF @accion = 'GUARDAR'
            IF @id IS NULL INSERT INTO TP_AREAS(nombre, ceco, cuenta, idproyecto, codfundo, idcultivo, idlabor)
                VALUES(JSON_VALUE(@json, '$.nombre'), JSON_VALUE(@json, '$.ceco'), JSON_VALUE(@json, '$.cuenta'),
                       JSON_VALUE(@json, '$.idproyecto'), JSON_VALUE(@json, '$.codfundo'),
                       JSON_VALUE(@json, '$.idcultivo'), JSON_VALUE(@json, '$.idlabor'));
            ELSE UPDATE TP_AREAS SET nombre = JSON_VALUE(@json, '$.nombre'),
                 ceco = JSON_VALUE(@json, '$.ceco'), cuenta = JSON_VALUE(@json, '$.cuenta'),
                 idproyecto = JSON_VALUE(@json, '$.idproyecto'), codfundo = JSON_VALUE(@json, '$.codfundo'),
                 idcultivo = JSON_VALUE(@json, '$.idcultivo'), idlabor = JSON_VALUE(@json, '$.idlabor'),
                 activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo) WHERE idArea = @id;
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_AREAS SET activo = 0 WHERE idArea = @id;
        SELECT idArea, nombre, ceco, cuenta, idproyecto, codfundo, idcultivo, idlabor, activo
        FROM TP_AREAS ORDER BY nombre FOR JSON PATH; RETURN;
    END
    IF @entidad = 'CECO'
    BEGIN
        IF @accion = 'GUARDAR'
        BEGIN
            IF JSON_VALUE(@json, '$.ceco') IS NULL
            BEGIN RAISERROR(N'El centro de costo es obligatorio',16,1); RETURN; END
            IF @id IS NULL AND EXISTS(SELECT 1 FROM TP_CECOS WHERE ceco = JSON_VALUE(@json, '$.ceco'))
            BEGIN RAISERROR(N'Ya existe un centro de costo con ese codigo',16,1); RETURN; END
            IF @id IS NULL INSERT INTO TP_CECOS(ceco, cuenta, idproyecto, codfundo, idcultivo, idlabor, descripcion)
                VALUES(JSON_VALUE(@json, '$.ceco'), JSON_VALUE(@json, '$.cuenta'), JSON_VALUE(@json, '$.idproyecto'),
                       JSON_VALUE(@json, '$.codfundo'), JSON_VALUE(@json, '$.idcultivo'), JSON_VALUE(@json, '$.idlabor'),
                       JSON_VALUE(@json, '$.descripcion'));
            ELSE UPDATE TP_CECOS SET ceco = JSON_VALUE(@json, '$.ceco'), cuenta = JSON_VALUE(@json, '$.cuenta'),
                 idproyecto = JSON_VALUE(@json, '$.idproyecto'), codfundo = JSON_VALUE(@json, '$.codfundo'),
                 idcultivo = JSON_VALUE(@json, '$.idcultivo'), idlabor = JSON_VALUE(@json, '$.idlabor'),
                 descripcion = JSON_VALUE(@json, '$.descripcion'),
                 activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo)
                 WHERE idCeco = @id;
        END
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_CECOS SET activo = 0 WHERE idCeco = @id;
        SELECT idCeco, ceco, cuenta, idproyecto, codfundo, idcultivo, idlabor, descripcion, activo
        FROM TP_CECOS ORDER BY ceco FOR JSON PATH; RETURN;
    END
    IF @entidad = 'UNIDAD'
    BEGIN
        IF @accion = 'GUARDAR'
        BEGIN
            DECLARE @placaU NVARCHAR(20) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@json, '$.placa'))), '');
            DECLARE @tipoProp NVARCHAR(10) = UPPER(COALESCE(NULLIF(JSON_VALUE(@json, '$.tipoPropiedad'), ''), 'PROPIA'));
            DECLARE @estadoOp NVARCHAR(20) = UPPER(COALESCE(NULLIF(JSON_VALUE(@json, '$.estadoOperativo'), ''), 'OPERATIVA'));
            DECLARE @idTransp INT = TRY_CAST(JSON_VALUE(@json, '$.idTransportista') AS INT);
            DECLARE @idCond INT = TRY_CAST(JSON_VALUE(@json, '$.idConductor') AS INT);
            IF @placaU IS NULL
            BEGIN RAISERROR(N'La placa es obligatoria',16,1); RETURN; END
            IF @tipoProp NOT IN ('PROPIA','TERCERO')
            BEGIN RAISERROR(N'tipoPropiedad debe ser PROPIA o TERCERO',16,1); RETURN; END
            IF @estadoOp NOT IN ('OPERATIVA','MANTENIMIENTO','FUERA_SERVICIO')
            BEGIN RAISERROR(N'estadoOperativo debe ser OPERATIVA, MANTENIMIENTO o FUERA_SERVICIO',16,1); RETURN; END
            -- flota mixta: la unidad de tercero exige su transportista; la propia no lleva
            IF @tipoProp = 'TERCERO' AND @idTransp IS NULL
            BEGIN RAISERROR(N'Una unidad de tercero requiere su transportista',16,1); RETURN; END
            IF @tipoProp = 'PROPIA' SET @idTransp = NULL;
            IF @idCond IS NOT NULL AND NOT EXISTS(
                SELECT 1 FROM TP_USUARIOS WHERE idUsuario = @idCond AND idrol = 'CHTRANS' AND activo = 1 AND eliminado = 0)
            BEGIN RAISERROR(N'El conductor asignado no es valido',16,1); RETURN; END
            -- el tipo de vehiculo debe existir en el catalogo TP_TIPOS_VEHICULO
            DECLARE @tipoVeh NVARCHAR(30) = NULLIF(LTRIM(RTRIM(JSON_VALUE(@json, '$.tipoVehiculo'))), '');
            IF @tipoVeh IS NOT NULL AND NOT EXISTS(
                SELECT 1 FROM TP_TIPOS_VEHICULO WHERE nombre = @tipoVeh AND activo = 1)
            BEGIN RAISERROR(N'El tipo de vehiculo no existe en el catalogo',16,1); RETURN; END
            IF @id IS NULL AND EXISTS(SELECT 1 FROM TP_UNIDADES WHERE placa = @placaU)
            BEGIN RAISERROR(N'Ya existe una unidad con esa placa',16,1); RETURN; END
            IF @id IS NULL INSERT INTO TP_UNIDADES(placa, capacidad, tipoPropiedad, tipoVehiculo,
                    marca, modelo, anio, estadoOperativo, idConductor, idTransportista)
                VALUES(@placaU, TRY_CAST(JSON_VALUE(@json, '$.capacidad') AS INT), @tipoProp,
                       @tipoVeh, JSON_VALUE(@json, '$.marca'),
                       JSON_VALUE(@json, '$.modelo'), TRY_CAST(JSON_VALUE(@json, '$.anio') AS INT),
                       @estadoOp, @idCond, @idTransp);
            ELSE UPDATE TP_UNIDADES SET placa = @placaU,
                 capacidad = TRY_CAST(JSON_VALUE(@json, '$.capacidad') AS INT),
                 tipoPropiedad = @tipoProp, tipoVehiculo = @tipoVeh,
                 marca = JSON_VALUE(@json, '$.marca'), modelo = JSON_VALUE(@json, '$.modelo'),
                 anio = TRY_CAST(JSON_VALUE(@json, '$.anio') AS INT),
                 estadoOperativo = @estadoOp, idConductor = @idCond, idTransportista = @idTransp,
                 activa = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activa)
                 WHERE idUnidad = @id;
        END
        ELSE IF @accion = 'ELIMINAR'
        BEGIN
            -- no se puede desactivar una unidad con traslados activos
            IF EXISTS(SELECT 1 FROM TP_UNIDADES u JOIN TP_TRASLADOS t ON t.placa = u.placa
                      WHERE u.idUnidad = @id AND t.estado IN ('PENDIENTE','ASIGNADO','EN_RUTA'))
            BEGIN RAISERROR(N'La unidad tiene traslados activos; no se puede desactivar',16,1); RETURN; END
            UPDATE TP_UNIDADES SET activa = 0 WHERE idUnidad = @id;
        END
        SELECT u.idUnidad, u.placa, u.capacidad, u.tipoPropiedad, u.tipoVehiculo, u.marca,
               u.modelo, u.anio, u.estadoOperativo, u.idConductor, c.nombre AS conductor,
               u.idTransportista, t.razonSocial AS transportista, u.activa AS activo
        FROM TP_UNIDADES u
        LEFT JOIN TP_TRANSPORTISTAS t ON t.idTransportista = u.idTransportista
        LEFT JOIN TP_USUARIOS c ON c.idUsuario = u.idConductor
        ORDER BY u.placa FOR JSON PATH; RETURN;
    END
    IF @entidad = 'TRANSPORTISTA'
    BEGIN
        IF @accion = 'GUARDAR'
        BEGIN
            IF @id IS NULL AND EXISTS(SELECT 1 FROM TP_TRANSPORTISTAS WHERE ruc = JSON_VALUE(@json, '$.ruc'))
            BEGIN RAISERROR(N'Ya existe un transportista con ese RUC',16,1); RETURN; END
            IF @id IS NULL INSERT INTO TP_TRANSPORTISTAS(ruc, razonSocial, telefono, email)
                VALUES(JSON_VALUE(@json, '$.ruc'), JSON_VALUE(@json, '$.razonSocial'),
                       JSON_VALUE(@json, '$.telefono'), JSON_VALUE(@json, '$.email'));
            ELSE UPDATE TP_TRANSPORTISTAS SET ruc = JSON_VALUE(@json, '$.ruc'),
                 razonSocial = JSON_VALUE(@json, '$.razonSocial'), telefono = JSON_VALUE(@json, '$.telefono'),
                 email = JSON_VALUE(@json, '$.email'),
                 activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo)
                 WHERE idTransportista = @id;
        END
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_TRANSPORTISTAS SET activo = 0 WHERE idTransportista = @id;
        SELECT idTransportista, ruc, razonSocial, telefono, email, activo
        FROM TP_TRANSPORTISTAS ORDER BY razonSocial FOR JSON PATH; RETURN;
    END
    IF @entidad = 'TARIFA'
    BEGIN
        IF @accion = 'GUARDAR'
        BEGIN
            IF JSON_VALUE(@json, '$.idTransportista') IS NULL OR TRY_CAST(JSON_VALUE(@json, '$.monto') AS DECIMAL(12,2)) IS NULL
            BEGIN RAISERROR(N'Transportista y monto son obligatorios',16,1); RETURN; END
            IF @id IS NULL INSERT INTO TP_TARIFAS(idTransportista, puntoOrigen, puntoDestino, monto, porPasajero)
                VALUES(TRY_CAST(JSON_VALUE(@json, '$.idTransportista') AS INT),
                       NULLIF(JSON_VALUE(@json, '$.puntoOrigen'), ''), NULLIF(JSON_VALUE(@json, '$.puntoDestino'), ''),
                       TRY_CAST(JSON_VALUE(@json, '$.monto') AS DECIMAL(12,2)),
                       COALESCE(TRY_CAST(JSON_VALUE(@json, '$.porPasajero') AS BIT), 0));
            ELSE UPDATE TP_TARIFAS SET idTransportista = TRY_CAST(JSON_VALUE(@json, '$.idTransportista') AS INT),
                 puntoOrigen = NULLIF(JSON_VALUE(@json, '$.puntoOrigen'), ''),
                 puntoDestino = NULLIF(JSON_VALUE(@json, '$.puntoDestino'), ''),
                 monto = TRY_CAST(JSON_VALUE(@json, '$.monto') AS DECIMAL(12,2)),
                 porPasajero = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.porPasajero') AS BIT), porPasajero),
                 activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo)
                 WHERE idTarifa = @id;
        END
        ELSE IF @accion = 'ELIMINAR' UPDATE TP_TARIFAS SET activo = 0 WHERE idTarifa = @id;
        SELECT tf.idTarifa, tf.idTransportista, t.razonSocial AS transportista,
               tf.puntoOrigen, tf.puntoDestino, tf.monto, tf.porPasajero, tf.activo
        FROM TP_TARIFAS tf JOIN TP_TRANSPORTISTAS t ON t.idTransportista = tf.idTransportista
        ORDER BY t.razonSocial, tf.puntoOrigen FOR JSON PATH; RETURN;
    END
    IF @entidad = 'USUARIO'
    BEGIN
        DECLARE @idAreaU INT = TRY_CAST(JSON_VALUE(@json, '$.idArea') AS INT);
        DECLARE @areaNombre NVARCHAR(100) = COALESCE(
            (SELECT nombre FROM TP_AREAS WHERE idArea = @idAreaU),
            JSON_VALUE(@json, '$.area'));
        DECLARE @rolSol NVARCHAR(10) = JSON_VALUE(@json, '$.rolSolicitante');
        DECLARE @idrolNuevo NVARCHAR(10) = JSON_VALUE(@json, '$.idrol');
        DECLARE @usuarioNuevo NVARCHAR(50) = JSON_VALUE(@json, '$.usuario');
        DECLARE @rolObj NVARCHAR(10), @usuarioObj NVARCHAR(50), @eliminadoObj BIT, @placaObj NVARCHAR(20);
        IF @id IS NOT NULL
            SELECT @rolObj = idrol, @usuarioObj = usuario, @eliminadoObj = eliminado, @placaObj = placa
            FROM TP_USUARIOS WHERE idUsuario = @id;
        IF @accion = 'GUARDAR'
        BEGIN
            -- un coordinador solo gestiona conductores y supervisores
            IF @rolSol = 'COTRANS' AND (@idrolNuevo IS NULL OR @idrolNuevo NOT IN ('CHTRANS','SPTRANS')
                OR (@id IS NOT NULL AND @rolObj NOT IN ('CHTRANS','SPTRANS')))
            BEGIN RAISERROR(N'El coordinador solo puede gestionar conductores y supervisores',16,1); RETURN; END
            IF @id IS NOT NULL AND @eliminadoObj = 1
            BEGIN RAISERROR(N'El usuario esta eliminado; no se puede editar',16,1); RETURN; END
            IF @id IS NULL AND EXISTS(SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuarioNuevo)
            BEGIN RAISERROR(N'Ya existe un usuario con ese nombre de acceso',16,1); RETURN; END
            IF @id IS NULL INSERT INTO TP_USUARIOS(usuario, claveHash, claveVisible, nombre, idrol, placa, area, idArea, dni)
                VALUES(@usuarioNuevo, JSON_VALUE(@json, '$.claveHash'), JSON_VALUE(@json, '$.claveVisible'),
                       JSON_VALUE(@json, '$.nombre'), @idrolNuevo, JSON_VALUE(@json, '$.placa'), @areaNombre, @idAreaU,
                       JSON_VALUE(@json, '$.dni'));
            ELSE UPDATE TP_USUARIOS SET nombre = JSON_VALUE(@json, '$.nombre'), idrol = @idrolNuevo,
                 placa = JSON_VALUE(@json, '$.placa'), area = @areaNombre, idArea = @idAreaU,
                 dni = JSON_VALUE(@json, '$.dni'),
                 activo = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.activo') AS BIT), activo),
                 claveHash = COALESCE(NULLIF(JSON_VALUE(@json, '$.claveHash'), ''), claveHash),
                 claveVisible = COALESCE(NULLIF(JSON_VALUE(@json, '$.claveVisible'), ''), claveVisible)
                 WHERE idUsuario = @id;
        END
        ELSE IF @accion = 'ELIMINAR'
        BEGIN
            IF @id IS NULL OR @rolObj IS NULL
            BEGIN RAISERROR(N'Usuario no encontrado',16,1); RETURN; END
            IF @eliminadoObj = 1
            BEGIN RAISERROR(N'El usuario ya esta eliminado',16,1); RETURN; END
            IF @usuarioObj = @actor
            BEGIN RAISERROR(N'No puede eliminar su propio usuario',16,1); RETURN; END
            IF @rolSol = 'COTRANS' AND @rolObj NOT IN ('CHTRANS','SPTRANS')
            BEGIN RAISERROR(N'El coordinador solo puede eliminar conductores y supervisores',16,1); RETURN; END
            -- conductor con traslados activos no se puede eliminar
            IF @rolObj = 'CHTRANS' AND @placaObj IS NOT NULL AND EXISTS(
                SELECT 1 FROM TP_TRASLADOS t WHERE t.placa = @placaObj AND t.estado IN ('PENDIENTE','ASIGNADO','EN_RUTA'))
            BEGIN RAISERROR(N'El conductor tiene traslados activos; no se puede eliminar',16,1); RETURN; END
            -- supervisor con solicitudes activas no se puede eliminar
            IF @rolObj = 'SPTRANS' AND EXISTS(
                SELECT 1 FROM TP_SOLICITUDES s WHERE s.usuarioRegistra = @usuarioObj AND s.estado IN ('PENDIENTE','ASIGNADO','EN_RUTA'))
            BEGIN RAISERROR(N'El supervisor tiene solicitudes activas; no se puede eliminar',16,1); RETURN; END
            UPDATE TP_USUARIOS SET eliminado = 1, activo = 0,
                fechaEliminado = GETDATE(), usuarioElimina = @actor
                WHERE idUsuario = @id;
        END
        -- LISTAR: el coordinador solo ve conductores y supervisores
        SELECT idUsuario, usuario, nombre, idrol, placa, area, idArea, dni, claveVisible, activo, eliminado, fechaEliminado, usuarioElimina
        FROM TP_USUARIOS
        WHERE (@rolSol <> 'COTRANS' OR @rolSol IS NULL OR idrol IN ('CHTRANS','SPTRANS'))
        ORDER BY nombre FOR JSON PATH; RETURN;
    END
    RAISERROR(N'Entidad administrativa invalida', 16, 1);
END
GO
