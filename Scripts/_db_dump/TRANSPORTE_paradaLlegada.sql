-- ============================================================================
-- TRANSPORTE_PERSONAL - SPs nuevos de seguimiento de paradas
-- Patron del API: un parametro @json con el body completo; salida FOR JSON PATH.
-- La idempotencia offline (idOperacion) ya la resuelve BaseRepository contra
-- TP_OPERACIONES_CLIENTE antes de llamar al SP.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- POST paradas/llegada - PENDIENTE  EN_PARADA (solo la parada actual)
-- ----------------------------------------------------------------------------
CREATE   PROCEDURE TRANSPORTE_paradaLlegada
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idParada    INT          = TRY_CAST(JSON_VALUE(@json,'$.idParada') AS INT);
    DECLARE @horaCliente DATETIME2    = TRY_CAST(JSON_VALUE(@json,'$.horaCliente') AS DATETIME2);
    DECLARE @lat         DECIMAL(9,6) = TRY_CAST(JSON_VALUE(@json,'$.latitud') AS DECIMAL(9,6));
    DECLARE @lon         DECIMAL(9,6) = TRY_CAST(JSON_VALUE(@json,'$.longitud') AS DECIMAL(9,6));
    DECLARE @usuario     NVARCHAR(100)= JSON_VALUE(@json,'$.usuario');

    DECLARE @idTraslado INT, @estado VARCHAR(12), @orden INT;
    SELECT @idTraslado = idTraslado, @estado = estado, @orden = orden
    FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada;

    IF @idTraslado IS NULL BEGIN RAISERROR('Parada no encontrada',16,1); RETURN; END
    IF @estado = 'EN_PARADA' GOTO fin;  -- reintento: ya quedo marcada
    IF @estado <> 'PENDIENTE' BEGIN RAISERROR('La parada ya fue procesada',16,1); RETURN; END

    -- Solo la primera parada pendiente del recorrido puede activarse
    IF EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS
               WHERE idTraslado = @idTraslado AND orden < @orden AND estado = 'PENDIENTE')
    BEGIN RAISERROR('Hay paradas anteriores sin procesar',16,1); RETURN; END

    UPDATE TP_TRASLADO_PARADAS
    SET estado = 'EN_PARADA',
        horaLlegada = COALESCE(@horaCliente, GETDATE()),
        latitud = @lat, longitud = @lon,
        usuarioRegistra = @usuario, fechaRegistro = GETDATE()
    WHERE idParada = @idParada;

    UPDATE TP_TRASLADOS SET estado = 'EN_RUTA'
    WHERE idTraslado = @idTraslado AND estado IN ('PENDIENTE','ASIGNADO');

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('PARADA',@idParada,'LLEGADA',@usuario,@json);

    fin:
    SELECT idParada, idTraslado, punto, orden, estado, horaLlegada, horaSalida,
           subieronReal, bajaronReal
    FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada
    FOR JSON PATH;
END

