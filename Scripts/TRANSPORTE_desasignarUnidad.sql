-- DESASIGNAR UNIDAD  @json: { "idSolicitud": 9, "usuario": "admin.transporte" }
-- Libera las unidades asignadas (simple o multiple) y devuelve la solicitud a PENDIENTE.
-- Aplicado a TRANSPORTE_PERSONAL el 2026-10-06.
CREATE OR ALTER PROCEDURE TRANSPORTE_desasignarUnidad
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);

    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND estado = 'ASIGNADO')
    BEGIN RAISERROR('La solicitud no existe o no esta asignada', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND idTraslado IS NOT NULL)
    BEGIN RAISERROR('La solicitud pertenece a un traslado; use separar', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id AND estado <> 'ASIGNADO')
    BEGIN RAISERROR('Alguna unidad ya inicio el servicio; no se puede desasignar', 16, 1); RETURN; END

    DECLARE @placas TABLE (placa NVARCHAR(20));
    INSERT INTO @placas
        SELECT u.placa FROM TP_SOLICITUD_UNIDADES su
        JOIN TP_UNIDADES u ON u.idUnidad = su.idUnidad WHERE su.idSolicitud = @id;
    INSERT INTO @placas
        SELECT placa FROM TP_SOLICITUDES
        WHERE idSolicitud = @id AND placa IS NOT NULL AND placa <> 'MULTIPLE';

    DELETE FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @id;

    UPDATE TP_SOLICITUDES SET placa = NULL, estado = 'PENDIENTE' WHERE idSolicitud = @id;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT usr.idUsuario, 'Servicio desasignado', CONCAT('La solicitud #', @id, ' fue desasignada de su unidad'), 'ESTADO'
    FROM TP_USUARIOS usr JOIN @placas p ON usr.placa = p.placa WHERE usr.activo = 1;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud desasignada', CONCAT('Su solicitud #', @id, ' fue desasignada y volvio a Pendiente'), 'ESTADO'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @id AND u.activo = 1;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @id, 'DESASIGNAR_UNIDAD', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
