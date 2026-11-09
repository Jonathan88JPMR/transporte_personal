-- =====================================================================
-- Fix: SPs creados con QUOTED_IDENTIFIER OFF
--
-- TP_SOLICITUD_UNIDADES (entre otras) tiene indices filtrados. SQL Server
-- guarda QUOTED_IDENTIFIER al crear el SP y lo aplica en cada ejecucion;
-- si quedo OFF, cualquier UPDATE/INSERT sobre tablas con indices
-- filtrados falla con Msg 1934 ('QUOTED_IDENTIFIER'). Aqui se recrean con
-- ALTER bajo SET QUOTED_IDENTIFIER ON usando la definicion VIVA.
-- =====================================================================
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

ALTER PROCEDURE TRANSPORTE_eliminarSolicitud
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

    UPDATE TP_SOLICITUDES SET estado = 'ANULADO' WHERE idSolicitud = @id;
    UPDATE TP_SOLICITUD_UNIDADES SET estado = 'ANULADO' WHERE idSolicitud = @id;

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle) VALUES('SOLICITUD',@id,'ANULAR',JSON_VALUE(@json,'$.usuario'),@json);

    SELECT @id AS idSolicitud, 'ANULADO' AS estado FOR JSON PATH;
END


GO

ALTER PROCEDURE TRANSPORTE_guardarSolicitud
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

ALTER PROCEDURE TRANSPORTE_listarServiciosConductor
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

--
-- 1) TRANSPORTE_listarSolicitudes: se quita el filtro por idArea del
--    supervisor, asi cualquier supervisor ve las solicitudes de todas
--    las areas (el frontend ya las muestra todas).
-- 2) TRANSPORTE_guardarSolicitud / TRANSPORTE_eliminarSolicitud: guarda
--    server-side ƒ?" un SPTRANS solo puede editar/anular solicitudes de
--    su area (o las que registro el, si no tiene area), igual que la
--    guarda que ya existia en TRANSPORTE_acoplarSolicitud.
-- =====================================================================

-- 1) Listar: sin filtro por area del supervisor
ALTER PROCEDURE TRANSPORTE_listarSolicitudes
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @fecha  DATE = TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE);
    DECLARE @estado NVARCHAR(20) = JSON_VALUE(@json, '$.estado');
    -- $.usuario sigue llegando en el JSON pero ya no filtra el resultado

    SELECT s.idSolicitud, s.idTraslado, s.idArea, s.nombre, COALESCE(a.nombre, s.area) AS area,
           s.fechaProgramada, s.horaProgramada, s.horaRequerida, s.puntoPartida, s.puntoLlegada, s.cantidad,
           s.motivo, s.observacion, s.prioridad, s.esEmergencia, s.placa,
           s.realizado, s.estado, s.usuarioRegistra, s.fechaRegistro, s.fechaInicio, s.fechaFin
    FROM TP_SOLICITUDES s
    LEFT JOIN TP_AREAS a ON a.idArea = s.idArea
    WHERE (@fecha  IS NULL OR s.fechaProgramada = @fecha)
      AND (@estado IS NULL OR s.estado = @estado)
    -- RN-004: prioridad primero (emergencias al tope), luego orden de registro
    ORDER BY CASE s.prioridad WHEN 'EMERGENCIA' THEN 0 WHEN 'ALTA' THEN 1 ELSE 2 END,
             s.fechaRegistro, s.idSolicitud
    FOR JSON PATH;
END


GO

ALTER PROCEDURE TRANSPORTE_listarTraslados
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

-- 1) cupoDisponible/diponible incluyen porciones TP_SOLICITUD_UNIDADES
-- 2) asignar/unir/asignar-multiples validan contra cupo DISPONIBLE por fecha
-- 3) anular marca porciones ANULADO
-- 4) listarTraslados excluye solicitudes anuladas
-- 5) marcarRealizado propaga a porciones
-- =====================================================================

-- 1) LISTAR UNIDADES: cupoDisponible con porciones incluidas
ALTER PROCEDURE TRANSPORTE_listarUnidades @json NVARCHAR(MAX)
AS BEGIN
    DECLARE @fecha DATE = COALESCE(TRY_CAST(JSON_VALUE(@json, '$.fecha') AS DATE), CAST(GETDATE() AS DATE));

    SELECT u.idUnidad, u.placa, u.capacidad,
           CASE WHEN EXISTS (SELECT 1 FROM TP_SOLICITUDES s
                             WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                               AND s.estado IN ('ASIGNADO', 'EN_RUTA'))
                OR EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES su
                           JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                           WHERE su.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                             AND su.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO')
                THEN CAST(0 AS BIT) ELSE CAST(1 AS BIT) END AS disponible,
           u.capacidad
             - COALESCE((SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
                         WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                           AND s.estado IN ('ASIGNADO', 'EN_RUTA')), 0)
             - COALESCE((SELECT SUM(su.cantidadAsignada) FROM TP_SOLICITUD_UNIDADES su
                         JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su.idSolicitud
                         WHERE su.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                           AND su.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO'), 0)
               AS cupoDisponible
    FROM TP_UNIDADES u WHERE u.activa = 1 ORDER BY u.placa FOR JSON PATH;
END


GO

ALTER PROCEDURE TRANSPORTE_reporteIndicadores
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

ALTER PROCEDURE TRANSPORTE_reporteSolicitudes
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
