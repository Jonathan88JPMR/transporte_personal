-- =====================================================================
-- Fixes de cupo real y consistencia de estados (aplicado 2026-10-06)
-- 1) cupoDisponible/diponible incluyen porciones TP_SOLICITUD_UNIDADES
-- 2) asignar/unir/asignar-multiples validan contra cupo DISPONIBLE por fecha
-- 3) anular marca porciones ANULADO
-- 4) listarTraslados excluye solicitudes anuladas
-- 5) marcarRealizado propaga a porciones
-- =====================================================================

-- 1) LISTAR UNIDADES: cupoDisponible con porciones incluidas
CREATE   PROCEDURE TRANSPORTE_listarUnidades @json NVARCHAR(MAX)
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

