
-- ----------------------------------------------------------------------------
-- POST paradas/registrar - EN_PARADA  REALIZADA con conteos reales
-- (si llega en PENDIENTE graba llegada y salida en un solo paso)
-- ----------------------------------------------------------------------------
CREATE   PROCEDURE TRANSPORTE_paradaRegistrar
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idParada     INT           = TRY_CAST(JSON_VALUE(@json,'$.idParada') AS INT);
    DECLARE @subieronReal INT           = TRY_CAST(JSON_VALUE(@json,'$.subieronReal') AS INT);
    DECLARE @bajaronReal  INT           = TRY_CAST(JSON_VALUE(@json,'$.bajaronReal') AS INT);
    DECLARE @horaCliente  DATETIME2     = TRY_CAST(JSON_VALUE(@json,'$.horaCliente') AS DATETIME2);
    DECLARE @lat          DECIMAL(9,6)  = TRY_CAST(JSON_VALUE(@json,'$.latitud') AS DECIMAL(9,6));
    DECLARE @lon          DECIMAL(9,6)  = TRY_CAST(JSON_VALUE(@json,'$.longitud') AS DECIMAL(9,6));
    DECLARE @usuario      NVARCHAR(100) = JSON_VALUE(@json,'$.usuario');
    DECLARE @detalle      NVARCHAR(MAX) = JSON_QUERY(@json,'$.detalle');

    DECLARE @idTraslado INT, @estado VARCHAR(12), @orden INT;
    SELECT @idTraslado = idTraslado, @estado = estado, @orden = orden
    FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada;

    IF @idTraslado IS NULL BEGIN RAISERROR('Parada no encontrada',16,1); RETURN; END
    IF @estado = 'REALIZADA' GOTO fin;  -- reintento: ya quedo registrada
    IF @estado = 'OMITIDA'   BEGIN RAISERROR('La parada fue omitida',16,1); RETURN; END
    IF @subieronReal IS NULL OR @bajaronReal IS NULL OR @subieronReal < 0 OR @bajaronReal < 0
    BEGIN RAISERROR('Conteos invalidos',16,1); RETURN; END

    -- Capacidad: el a bordo resultante no puede exceder la unidad
    DECLARE @aBordo INT, @capacidad INT;
    SELECT @capacidad = u.capacidad
    FROM TP_TRASLADOS t JOIN TP_UNIDADES u ON u.placa = t.placa
    WHERE t.idTraslado = @idTraslado;

    SELECT @aBordo = SUM(COALESCE(subieronReal, cantidadSube, 0)
                       - COALESCE(bajaronReal,  cantidadBaja, 0))
    FROM TP_TRASLADO_PARADAS
    WHERE idTraslado = @idTraslado AND orden < @orden AND estado = 'REALIZADA';

    SET @aBordo = COALESCE(@aBordo, 0) + @subieronReal - @bajaronReal;

    IF @capacidad IS NOT NULL AND @aBordo > @capacidad
    BEGIN RAISERROR('Los pasajeros a bordo exceden la capacidad de la unidad',16,1); RETURN; END

    BEGIN TRANSACTION;

    UPDATE TP_TRASLADO_PARADAS
    SET estado = 'REALIZADA',
        subieronReal = @subieronReal,
        bajaronReal  = @bajaronReal,
        horaLlegada  = COALESCE(horaLlegada, @horaCliente, GETDATE()),
        horaSalida   = COALESCE(@horaCliente, GETDATE()),
        latitud  = COALESCE(@lat, latitud),
        longitud = COALESCE(@lon, longitud),
        usuarioRegistra = @usuario, fechaRegistro = GETDATE()
    WHERE idParada = @idParada;

    -- Conteo real por solicitud, si el conductor lo detallo
    IF @detalle IS NOT NULL
        UPDATE d SET d.cantidadReal = TRY_CAST(JSON_VALUE(j.value,'$.cantidadReal') AS INT)
        FROM TP_PARADA_DETALLE d
        JOIN OPENJSON(@detalle) j
          ON d.idParadaDetalle = TRY_CAST(JSON_VALUE(j.value,'$.idParadaDetalle') AS INT)
        WHERE d.idParada = @idParada
          AND JSON_VALUE(j.value,'$.cantidadReal') IS NOT NULL;

    -- Sin paradas pendientes el traslado queda ejecutado
    IF NOT EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS
                   WHERE idTraslado = @idTraslado AND estado IN ('PENDIENTE','EN_PARADA'))
        UPDATE TP_TRASLADOS SET estado = 'REALIZADO' WHERE idTraslado = @idTraslado;

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('PARADA',@idParada,'REGISTRAR',@usuario,@json);

    COMMIT;

    fin:
    SELECT idParada, idTraslado, punto, orden, estado, horaLlegada, horaSalida,
           subieronReal, bajaronReal
    FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada
    FOR JSON PATH;
END

