
-- ----------------------------------------------------------------------------
-- POST paradas/omitir - PENDIENTE/EN_PARADA  OMITIDA
-- ----------------------------------------------------------------------------
CREATE   PROCEDURE TRANSPORTE_paradaOmitir
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idParada    INT           = TRY_CAST(JSON_VALUE(@json,'$.idParada') AS INT);
    DECLARE @motivo      NVARCHAR(200) = JSON_VALUE(@json,'$.motivo');
    DECLARE @horaCliente DATETIME2     = TRY_CAST(JSON_VALUE(@json,'$.horaCliente') AS DATETIME2);
    DECLARE @usuario     NVARCHAR(100) = JSON_VALUE(@json,'$.usuario');

    DECLARE @estado VARCHAR(12), @previsto INT, @idTraslado INT;
    SELECT @estado = estado, @idTraslado = idTraslado,
           @previsto = COALESCE(cantidadSube,0) + COALESCE(cantidadBaja,0)
    FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada;

    IF @estado IS NULL BEGIN RAISERROR('Parada no encontrada',16,1); RETURN; END
    IF @estado IN ('REALIZADA','OMITIDA') BEGIN RAISERROR('La parada ya fue procesada',16,1); RETURN; END
    IF @previsto > 0 AND NULLIF(LTRIM(RTRIM(@motivo)),'') IS NULL
    BEGIN RAISERROR('La parada tenia movimiento previsto; indique el motivo',16,1); RETURN; END

    UPDATE TP_TRASLADO_PARADAS
    SET estado = 'OMITIDA', motivoOmision = @motivo,
        horaSalida = COALESCE(@horaCliente, GETDATE()),
        usuarioRegistra = @usuario, fechaRegistro = GETDATE()
    WHERE idParada = @idParada;

    -- Sin paradas pendientes el traslado queda ejecutado
    IF NOT EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS
                   WHERE idTraslado = @idTraslado AND estado IN ('PENDIENTE','EN_PARADA'))
        UPDATE TP_TRASLADOS SET estado = 'REALIZADO' WHERE idTraslado = @idTraslado;

    INSERT INTO TP_AUDITORIA(entidad,idEntidad,accion,usuario,detalle)
    VALUES('PARADA',@idParada,'OMITIR',@usuario,@json);

    SELECT idParada, idTraslado, punto, orden, estado, motivoOmision
    FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada
    FOR JSON PATH;
END

