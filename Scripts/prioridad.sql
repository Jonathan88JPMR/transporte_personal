-- =====================================================================
-- Prioridad de 3 niveles: NORMAL / ALTA / EMERGENCIA (default NORMAL)
-- 1) TP_SOLICITUDES.prioridad + backfill desde esEmergencia
-- 2) TP_SOLICITUD_UNIDADES.esEmergencia (emergencia a nivel porcion)
-- 3) guardarSolicitud acepta prioridad y sincroniza esEmergencia
-- 4) listados ordenan por prioridad
-- 5) agregarPasajeros marca emergencia solo en la porcion (o padre si es simple)
-- =====================================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('TP_SOLICITUDES') AND name = 'prioridad')
    ALTER TABLE TP_SOLICITUDES ADD prioridad NVARCHAR(15) NOT NULL CONSTRAINT DF_SOL_PRIORIDAD DEFAULT 'NORMAL';
IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('TP_SOLICITUD_UNIDADES') AND name = 'esEmergencia')
    ALTER TABLE TP_SOLICITUD_UNIDADES ADD esEmergencia BIT NOT NULL CONSTRAINT DF_SU_EMERGENCIA DEFAULT 0;
GO
UPDATE TP_SOLICITUDES SET prioridad = 'EMERGENCIA' WHERE esEmergencia = 1 AND prioridad <> 'EMERGENCIA';
GO

-- Guardar solicitud con prioridad
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

    IF @idSolicitud IS NULL OR @idSolicitud = 0
    BEGIN
        INSERT INTO TP_SOLICITUDES (nombre, area, idArea, fechaProgramada, horaProgramada, puntoPartida, puntoLlegada,
                                    cantidad, motivo, observacion, prioridad, esEmergencia, usuarioRegistra)
        SELECT JSON_VALUE(@json, '$.nombre'), @areaNombre, @idArea,
               COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fechaProgramada') AS DATE), CAST(GETDATE() AS DATE)),
               JSON_VALUE(@json, '$.horaProgramada'), JSON_VALUE(@json, '$.puntoPartida'),
               JSON_VALUE(@json, '$.puntoLlegada'), TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT),
               JSON_VALUE(@json, '$.motivo'), JSON_VALUE(@json, '$.observacion'),
               @prioridad, CASE WHEN @prioridad = 'EMERGENCIA' THEN 1 ELSE 0 END, @usuario;
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
            prioridad      = COALESCE(NULLIF(JSON_VALUE(@json, '$.prioridad'), ''), prioridad),
            esEmergencia   = CASE WHEN COALESCE(NULLIF(JSON_VALUE(@json, '$.prioridad'), ''), prioridad) = 'EMERGENCIA' THEN 1 ELSE 0 END
        WHERE idSolicitud = @idSolicitud;
    END

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('SOLICITUD',@idSolicitud,CASE WHEN JSON_VALUE(@json,'$.idSolicitud') IS NULL THEN 'CREAR' ELSE 'EDITAR' END,JSON_VALUE(@json,'$.usuarioRegistra'),@json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

-- Listar solicitudes: orden por prioridad (EMERGENCIA > ALTA > NORMAL)
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
           s.motivo, s.observacion, s.prioridad, s.esEmergencia, s.placa,
           s.realizado, s.estado, s.usuarioRegistra, s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
    WHERE (@fecha  IS NULL OR s.fechaProgramada = @fecha)
      AND (@estado IS NULL OR s.estado = @estado)
      AND (@usuario IS NULL OR @idAreaFiltro IS NULL OR s.idArea = @idAreaFiltro)
    -- RN-004: prioridad primero (emergencias al tope), luego orden de registro
    ORDER BY CASE s.prioridad WHEN 'EMERGENCIA' THEN 0 WHEN 'ALTA' THEN 1 ELSE 2 END,
             s.fechaRegistro, s.idSolicitud
    FOR JSON PATH;
END
GO

-- Servicios del conductor: prioridad efectiva (la porcion puede ser emergencia)
CREATE OR ALTER PROCEDURE TRANSPORTE_listarServiciosConductor
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @fecha DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);

    SELECT s.idSolicitud, s.idTraslado, su.idSolicitudUnidad, s.nombre, s.area, s.fechaProgramada, s.horaProgramada,
           s.puntoPartida, s.puntoLlegada, COALESCE(su.cantidadAsignada,s.cantidad) cantidad, s.motivo, s.observacion,
           CASE WHEN COALESCE(su.esEmergencia, 0) = 1 THEN 'EMERGENCIA' ELSE s.prioridad END AS prioridad,
           CASE WHEN COALESCE(su.esEmergencia, 0) = 1 OR s.esEmergencia = 1 THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END AS esEmergencia,
           @placa placa,
           CASE WHEN su.idSolicitudUnidad IS NULL THEN s.realizado ELSE CASE WHEN su.estado='REALIZADO' THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END END realizado,
           COALESCE(su.estado,s.estado) estado, s.fechaInicio, s.fechaFin,
           t.ruta,
           -- RF-023: paradas ordenadas del traslado con cantidades por punto
           JSON_QUERY((SELECT p.punto, p.orden, p.cantidadSube, p.cantidadBaja
                       FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = s.idTraslado
                       ORDER BY p.orden FOR JSON PATH)) AS paradas
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_SOLICITUD_UNIDADES su ON su.idSolicitud=s.idSolicitud
    LEFT JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad
    LEFT JOIN TP_TRASLADOS t ON t.idTraslado = s.idTraslado
    WHERE (s.placa = @placa OR u.placa = @placa)
      AND s.estado <> 'ANULADO'
      AND (@fecha IS NULL OR s.fechaProgramada = @fecha)
    ORDER BY CASE WHEN COALESCE(su.esEmergencia,0)=1 OR s.prioridad='EMERGENCIA' THEN 0
                  WHEN s.prioridad='ALTA' THEN 1 ELSE 2 END,
             s.horaProgramada, s.idSolicitud
    FOR JSON PATH;
END
GO

-- Agregar pasajeros: la emergencia marca solo la porcion (o el padre si es asignacion simple)
CREATE OR ALTER PROCEDURE TRANSPORTE_agregarPasajeros
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idSolicitudUnidad INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitudUnidad') AS INT);
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

    -- Ocupacion actual de la unidad en el viaje
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

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'AGREGAR_PASAJEROS', JSON_VALUE(@json, '$.usuario'), @json);
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Pasajeros agregados', CONCAT(N'El conductor agrego ', @extra, ' pasajero(s) a la solicitud #', @idSolicitud), 'PASAJEROS'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @idSolicitud AND u.activo = 1;

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

-- Reporte de solicitudes: incluir prioridad
CREATE OR ALTER PROCEDURE TRANSPORTE_reporteSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @desde DATE = TRY_CAST(JSON_VALUE(@json, '$.desde') AS DATE);
    DECLARE @hasta DATE = TRY_CAST(JSON_VALUE(@json, '$.hasta') AS DATE);

    SELECT s.idSolicitud, s.idTraslado, s.idArea, s.nombre, s.usuarioRegistra, COALESCE(a.nombre, s.area) AS area,
           s.fechaProgramada, s.horaProgramada, s.puntoPartida, s.puntoLlegada, s.cantidad,
           s.motivo, s.observacion, s.prioridad, s.esEmergencia, s.placa, s.realizado, s.estado,
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
