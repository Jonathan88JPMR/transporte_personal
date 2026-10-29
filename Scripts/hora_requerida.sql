-- =====================================================================
-- Hora requerida vs hora de digitacion
-- 1) TP_SOLICITUDES.horaRequerida (cuando se necesita la movilidad);
--    horaProgramada queda como hora de digitacion (la fija el servidor)
-- 2) guardarSolicitud: insert/update de horaRequerida; horaProgramada
--    se sella con GETDATE() en el INSERT
-- 3) listados exponen horaRequerida y el conductor ordena por ella
--    (fallback a horaProgramada en registros antiguos)
-- 4) KPI puntualidad: se mide contra la hora requerida
-- =====================================================================

IF NOT EXISTS (SELECT 1 FROM sys.columns WHERE object_id = OBJECT_ID('TP_SOLICITUDES') AND name = 'horaRequerida')
    ALTER TABLE TP_SOLICITUDES ADD horaRequerida NVARCHAR(10) NULL;
GO
-- Registros antiguos: la hora requerida era la misma de digitacion
UPDATE TP_SOLICITUDES SET horaRequerida = horaProgramada WHERE horaRequerida IS NULL;
GO

-- Guardar solicitud: horaProgramada = digitacion (servidor), horaRequerida = del usuario
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

-- Listar solicitudes: incluye horaRequerida
CREATE OR ALTER PROCEDURE TRANSPORTE_listarSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha  DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);
    DECLARE @estado NVARCHAR(20) = JSON_VALUE(@json, '$.estado');
    DECLARE @usuario NVARCHAR(50) = JSON_VALUE(@json, '$.usuario');
    -- Si quien consulta es supervisor, solo ve solicitudes de su area
    DECLARE @idAreaFiltro INT = (SELECT idArea FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS');
    DECLARE @esSupervisor BIT = CASE WHEN EXISTS (SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS') THEN 1 ELSE 0 END;

    SELECT s.idSolicitud, s.idTraslado, s.idArea, s.nombre, COALESCE(a.nombre, s.area) AS area,
           s.fechaProgramada, s.horaProgramada, s.horaRequerida, s.puntoPartida, s.puntoLlegada, s.cantidad,
           s.motivo, s.observacion, s.prioridad, s.esEmergencia, s.placa,
           s.realizado, s.estado, s.usuarioRegistra, s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
    WHERE (@fecha  IS NULL OR s.fechaProgramada = @fecha)
      AND (@estado IS NULL OR s.estado = @estado)
      AND (@usuario IS NULL OR @esSupervisor = 0
           OR s.idArea = @idAreaFiltro
           OR (@idAreaFiltro IS NULL AND s.usuarioRegistra = @usuario))
    -- RN-004: prioridad primero (emergencias al tope), luego orden de registro
    ORDER BY CASE s.prioridad WHEN 'EMERGENCIA' THEN 0 WHEN 'ALTA' THEN 1 ELSE 2 END,
             s.fechaRegistro, s.idSolicitud
    FOR JSON PATH;
END
GO

-- Servicios del conductor: ordena por la hora en que se necesita la movilidad
CREATE OR ALTER PROCEDURE TRANSPORTE_listarServiciosConductor
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
             COALESCE(s.horaRequerida, s.horaProgramada), s.idSolicitud
    FOR JSON PATH;
END
GO

-- Listar traslados: las solicitudes del detalle incluyen horaRequerida
CREATE OR ALTER PROCEDURE TRANSPORTE_listarTraslados
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);

    SELECT t.idTraslado, t.placa, t.ruta, t.estado, t.fechaCreacion,
           JSON_QUERY((SELECT s.idSolicitud, s.nombre, s.horaProgramada, s.horaRequerida, s.puntoPartida,
                   s.puntoLlegada, s.cantidad, s.motivo, s.realizado, s.estado, s.esEmergencia
            FROM TP_SOLICITUDES s WHERE s.idTraslado = t.idTraslado AND s.estado <> 'ANULADO'
            FOR JSON PATH)) AS solicitudes,
           JSON_QUERY((SELECT p.idParada, p.idPunto, p.punto, p.orden, p.cantidadSube, p.cantidadBaja
            FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = t.idTraslado ORDER BY p.orden
            FOR JSON PATH)) AS paradas
    FROM TP_TRASLADOS t
    WHERE t.estado <> 'ANULADO'
      AND (@fecha IS NULL OR CAST(t.fechaCreacion AS DATE) = @fecha)
    ORDER BY t.fechaCreacion DESC
    FOR JSON PATH;
END
GO

-- Reporte de solicitudes: incluye horaRequerida
CREATE OR ALTER PROCEDURE TRANSPORTE_reporteSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @desde DATE = TRY_CAST(JSON_VALUE(@json, '$.desde') AS DATE);
    DECLARE @hasta DATE = TRY_CAST(JSON_VALUE(@json, '$.hasta') AS DATE);

    SELECT s.idSolicitud, s.idTraslado, s.idArea, s.nombre, s.usuarioRegistra, COALESCE(a.nombre, s.area) AS area,
           s.fechaProgramada, s.horaProgramada, s.horaRequerida, s.puntoPartida, s.puntoLlegada, s.cantidad,
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

-- Indicadores: la puntualidad se mide contra la hora requerida
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
      (SELECT COUNT(*) FROM TP_SOLICITUDES WHERE prioridad = 'EMERGENCIA' AND estado <> 'ANULADO' AND (@desde IS NULL OR fechaProgramada >= @desde) AND (@hasta IS NULL OR fechaProgramada <= @hasta)) totalEmergencias,
      (SELECT COALESCE(AVG(CAST(DATEDIFF(MINUTE,fechaInicio,fechaFin) AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND fechaFin IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) tiempoPromedioMinutos,
      (SELECT COALESCE(AVG(CAST(CASE WHEN DATEDIFF(MINUTE,fechaRegistro,fechaInicio)<0 THEN 0 ELSE DATEDIFF(MINUTE,fechaRegistro,fechaInicio) END AS DECIMAL(10,2))),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) esperaPromedioMinutos,
      (SELECT COALESCE(100.0*SUM(CASE WHEN ABS(DATEDIFF(MINUTE,DATEADD(MINUTE,DATEDIFF(MINUTE,0,TRY_CAST(COALESCE(horaRequerida,horaProgramada) AS TIME)),CAST(fechaProgramada AS DATETIME)),fechaInicio))<=10 THEN 1 ELSE 0 END)/NULLIF(COUNT(*),0),0) FROM TP_SOLICITUDES WHERE fechaInicio IS NOT NULL AND (@desde IS NULL OR fechaProgramada>=@desde) AND (@hasta IS NULL OR fechaProgramada<=@hasta)) puntualidadPorcentaje,
      JSON_QUERY((SELECT placa, COUNT(*) viajes, SUM(personas) personas,
                         CAST(100.0 * SUM(personas) / NULLIF(COUNT(*) * MAX(capacidad), 0) AS DECIMAL(6,2)) ocupacionPorcentaje
                  FROM (
                      SELECT s.placa, s.cantidad AS personas, u.capacidad
                      FROM TP_SOLICITUDES s JOIN TP_UNIDADES u ON u.placa = s.placa
                      WHERE s.estado <> 'ANULADO' AND s.placa IS NOT NULL AND s.placa <> 'MULTIPLE'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                      UNION ALL
                      SELECT u.placa, su.cantidadAsignada, u.capacidad
                      FROM TP_SOLICITUD_UNIDADES su
                      JOIN TP_UNIDADES u ON u.idUnidad = su.idUnidad
                      JOIN TP_SOLICITUDES s ON s.idSolicitud = su.idSolicitud
                      WHERE su.estado <> 'ANULADO' AND s.estado <> 'ANULADO'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  ) x GROUP BY placa FOR JSON PATH)) unidades,
      JSON_QUERY((SELECT COALESCE(a.nombre, s.area) AS area, COUNT(*) solicitudes, SUM(s.cantidad) personas
                  FROM TP_SOLICITUDES s LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
                  WHERE s.estado <> 'ANULADO' AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  GROUP BY COALESCE(a.nombre, s.area) FOR JSON PATH)) areas,
      JSON_QUERY((SELECT u.nombre conductor, u.placa, COUNT(x.idSolicitud) servicios, COALESCE(SUM(x.personas),0) personas
                  FROM TP_USUARIOS u
                  LEFT JOIN (
                      SELECT s.placa, s.idSolicitud, s.cantidad AS personas
                      FROM TP_SOLICITUDES s
                      WHERE s.estado = 'REALIZADO' AND s.placa IS NOT NULL AND s.placa <> 'MULTIPLE'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                      UNION ALL
                      SELECT u2.placa, s.idSolicitud, su.cantidadAsignada
                      FROM TP_SOLICITUD_UNIDADES su
                      JOIN TP_UNIDADES u2 ON u2.idUnidad = su.idUnidad
                      JOIN TP_SOLICITUDES s ON s.idSolicitud = su.idSolicitud
                      WHERE su.estado = 'REALIZADO'
                        AND (@desde IS NULL OR s.fechaProgramada >= @desde) AND (@hasta IS NULL OR s.fechaProgramada <= @hasta)
                  ) x ON x.placa = u.placa
                  WHERE u.idrol = 'CHTRANS' AND u.activo = 1
                  GROUP BY u.nombre, u.placa FOR JSON PATH)) conductores
    FOR JSON PATH;
END
GO
