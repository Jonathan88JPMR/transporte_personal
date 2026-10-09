SET NOCOUNT ON;
INSERT INTO TP_TRASLADOS(placa, ruta, estado) VALUES('TP-001','Test','ASIGNADO');
DECLARE @t INT = SCOPE_IDENTITY();
INSERT INTO TP_SOLICITUDES(nombre, idArea, area, fechaProgramada, horaProgramada, puntoPartida, puntoLlegada, cantidad, motivo, estado, usuarioRegistra)
VALUES('Test Otra Area', 3, 'Transportes', '2026-10-06', '10:00', 'Acopio Principal', 'Garita Principal', 2, 'Actividad', 'PENDIENTE', 'admin.transporte');
DECLARE @s INT = SCOPE_IDENTITY();
DECLARE @j1 NVARCHAR(MAX) = N'{"idSolicitud":' + CAST(@s AS NVARCHAR) + N',"idTraslado":' + CAST(@t AS NVARCHAR) + N',"usuario":"supervisor.transporte"}';
DECLARE @j2 NVARCHAR(MAX) = N'{"idSolicitud":' + CAST(@s AS NVARCHAR) + N',"idTraslado":' + CAST(@t AS NVARCHAR) + N',"usuario":"admin.transporte"}';
PRINT '--- supervisor (area 1) intenta acoplar solicitud de area 3 (debe FALLAR):';
EXEC TRANSPORTE_acoplarSolicitud @json=@j1;
PRINT '--- admin acopla la misma solicitud (debe PASAR):';
EXEC TRANSPORTE_acoplarSolicitud @json=@j2;
DELETE FROM TP_NOTIFICACIONES WHERE mensaje LIKE N'%acoplo al traslado T-' + CAST(@t AS NVARCHAR) + N'%';
DELETE FROM TP_AUDITORIA WHERE entidad='SOLICITUD' AND idEntidad=@s;
DELETE FROM TP_SOLICITUDES WHERE idSolicitud=@s;
DELETE FROM TP_TRASLADOS WHERE idTraslado=@t;
PRINT '--- datos temporales eliminados';
