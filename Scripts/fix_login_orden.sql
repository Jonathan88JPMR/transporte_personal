-- Login: claveHash debe quedar en la posicion 7 (el controller la lee por indice).
-- idArea se agrega al final (posicion 8) sin romper el orden existente.
CREATE OR ALTER PROCEDURE TRANSPORTE_login
    @usuario   NVARCHAR(50),
    @claveHash NVARCHAR(200)
AS
BEGIN
    SELECT u.idUsuario, u.usuario, u.nombre, u.idrol,
           CASE u.idrol
               WHEN 'SPTRANS' THEN 'SUPERVISOR'
               WHEN 'COTRANS' THEN 'COORDINADOR'
               WHEN 'CHTRANS' THEN 'CONDUCTOR'
               WHEN 'ADTRANS' THEN 'ADMINISTRADOR'
               ELSE u.idrol
           END AS rol,
           u.placa, u.area, u.claveHash, u.idArea
    FROM TP_USUARIOS u
    WHERE u.usuario = @usuario AND u.activo = 1;
END
GO
