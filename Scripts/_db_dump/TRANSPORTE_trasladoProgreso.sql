
-- ----------------------------------------------------------------------------
-- trasladoProgreso: incluye la ultima posicion GPS para el modal de progreso
-- ----------------------------------------------------------------------------
CREATE   PROCEDURE TRANSPORTE_trasladoProgreso
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idTraslado INT = TRY_CAST(JSON_VALUE(@json,'$.idTraslado') AS INT);

    SELECT t.idTraslado, t.placa, t.estado AS estadoTraslado,
           t.ultimaLatitud, t.ultimaLongitud,
           CONVERT(VARCHAR(33), t.ultimaUbicacionAt, 126) AS ultimaUbicacionAt,
           (SELECT COUNT(*) FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = t.idTraslado) AS totalParadas,
           (SELECT COUNT(*) FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = t.idTraslado
             AND p.estado IN ('REALIZADA','OMITIDA')) AS realizadas,
           (SELECT MIN(p.orden) FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = t.idTraslado
             AND p.estado IN ('PENDIENTE','EN_PARADA')) AS paradaActual,
           COALESCE((SELECT SUM(COALESCE(p.subieronReal,p.cantidadSube,0)
                              - COALESCE(p.bajaronReal, p.cantidadBaja,0))
                     FROM TP_TRASLADO_PARADAS p
                     WHERE p.idTraslado = t.idTraslado
                       AND p.estado IN ('REALIZADA','EN_PARADA')),0) AS aBordo,
           JSON_QUERY((SELECT p.idParada, p.idPunto, p.punto, p.orden,
                   p.cantidadSube, p.cantidadBaja,
                   p.subieronReal, p.bajaronReal, p.estado,
                   CONVERT(VARCHAR(33), p.horaLlegada, 126) AS horaLlegada,
                   CONVERT(VARCHAR(33), p.horaSalida,  126) AS horaSalida,
                   p.motivoOmision,
                   JSON_QUERY((SELECT d.idParadaDetalle, d.idSolicitud, d.idSolicitudUnidad,
                               d.tipo, d.cantidadPlaneada, d.cantidadReal, s.nombre
                        FROM TP_PARADA_DETALLE d
                        LEFT JOIN TP_SOLICITUDES s ON s.idSolicitud = d.idSolicitud
                        WHERE d.idParada = p.idParada
                        FOR JSON PATH)) AS detalle
            FROM TP_TRASLADO_PARADAS p
            WHERE p.idTraslado = t.idTraslado
            ORDER BY p.orden
            FOR JSON PATH)) AS paradas
    FROM TP_TRASLADOS t
    WHERE t.idTraslado = @idTraslado
    FOR JSON PATH;
END

