
/* asignarMultiplesUnidades: mismo control, cada unidad de la distribuciÇün
   debe existir, estar activa y en estadoOperativo='OPERATIVA'. */
CREATE   PROCEDURE TRANSPORTE_asignarMultiplesUnidades
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @requerido INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud);
    DECLARE @fecha DATE = (SELECT fechaProgramada FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud);
    DECLARE @asignado INT;

    SELECT @asignado = SUM(TRY_CAST(JSON_VALUE(value, '$.cantidad') AS INT)) FROM OPENJSON(@json, '$.unidades');

    IF @requerido IS NULL OR @asignado <> @requerido
    BEGIN RAISERROR(N'La distribucion debe cubrir exactamente la cantidad solicitada', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud AND estado IN ('EN_RUTA', 'REALIZADO', 'ANULADO'))
    BEGIN RAISERROR('La solicitud ya esta en curso, realizada o anulada', 16, 1); RETURN; END

    -- Una placa no puede repetirse en la distribucion
    IF EXISTS (SELECT 1 FROM OPENJSON(@json, '$.unidades') j
               GROUP BY JSON_VALUE(j.value, '$.placa') HAVING COUNT(*) > 1)
    BEGIN RAISERROR('No se puede repetir la misma unidad en la distribucion', 16, 1); RETURN; END

    -- Cada unidad debe existir, estar activa/operativa y tener cupo libre suficiente
    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@json, '$.unidades') j
        LEFT JOIN TP_UNIDADES u ON u.placa = JSON_VALUE(j.value, '$.placa') AND u.activa = 1 AND u.estadoOperativo = 'OPERATIVA'
        WHERE u.idUnidad IS NULL
           OR TRY_CAST(JSON_VALUE(j.value, '$.cantidad') AS INT) >
              u.capacidad
              - COALESCE((SELECT SUM(s.cantidad) FROM TP_SOLICITUDES s
                          WHERE s.placa = u.placa AND s.fechaProgramada = @fecha
                            AND s.estado IN ('ASIGNADO', 'EN_RUTA') AND s.idSolicitud <> @idSolicitud), 0)
              - COALESCE((SELECT SUM(su2.cantidadAsignada) FROM TP_SOLICITUD_UNIDADES su2
                          JOIN TP_SOLICITUDES s2 ON s2.idSolicitud = su2.idSolicitud
                          WHERE su2.idUnidad = u.idUnidad AND s2.fechaProgramada = @fecha
                            AND su2.estado IN ('ASIGNADO', 'EN_RUTA') AND s2.estado <> 'ANULADO'
                            AND s2.idSolicitud <> @idSolicitud), 0)
    )
    BEGIN RAISERROR('Una unidad no existe, no esta operativa o no tiene cupo suficiente para esa fecha', 16, 1); RETURN; END

    -- Reasignacion: disolver los traslados de las porciones anteriores
    DELETE d FROM TP_PARADA_DETALLE d
    JOIN TP_TRASLADO_PARADAS p ON p.idParada = d.idParada
    WHERE p.idTraslado IN (SELECT idTraslado FROM TP_SOLICITUD_UNIDADES
                           WHERE idSolicitud = @idSolicitud AND idTraslado IS NOT NULL);
    DELETE p FROM TP_TRASLADO_PARADAS p
    WHERE p.idTraslado IN (SELECT idTraslado FROM TP_SOLICITUD_UNIDADES
                           WHERE idSolicitud = @idSolicitud AND idTraslado IS NOT NULL);
    UPDATE TP_TRASLADOS SET estado = 'ANULADO'
    WHERE idTraslado IN (SELECT idTraslado FROM TP_SOLICITUD_UNIDADES
                         WHERE idSolicitud = @idSolicitud AND idTraslado IS NOT NULL);

    DELETE FROM TP_SOLICITUD_UNIDADES WHERE idSolicitud = @idSolicitud;

    INSERT INTO TP_SOLICITUD_UNIDADES(idSolicitud, idUnidad, cantidadAsignada)
    SELECT @idSolicitud, u.idUnidad, TRY_CAST(JSON_VALUE(j.value, '$.cantidad') AS INT)
    FROM OPENJSON(@json, '$.unidades') j JOIN TP_UNIDADES u ON u.placa = JSON_VALUE(j.value, '$.placa');

    -- Traslado implicito por porcion: cada unidad recorre origen -> destino
    DECLARE @origen NVARCHAR(300), @destino NVARCHAR(300);
    SELECT @origen = puntoPartida, @destino = puntoLlegada
    FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud;
    DECLARE @ruta NVARCHAR(600) = CONCAT(@origen, ' > ', @destino);
    DECLARE @idPuntoO INT = (SELECT TOP 1 idPunto FROM TP_PUNTOS WHERE nombre = @origen  AND activo = 1);
    DECLARE @idPuntoD INT = (SELECT TOP 1 idPunto FROM TP_PUNTOS WHERE nombre = @destino AND activo = 1);

    DECLARE @su INT, @cant INT, @idTraslado INT, @idParada INT;
    DECLARE cur CURSOR LOCAL FAST_FORWARD FOR
        SELECT su.idSolicitudUnidad, su.cantidadAsignada
        FROM TP_SOLICITUD_UNIDADES su WHERE su.idSolicitud = @idSolicitud;
    OPEN cur;
    FETCH NEXT FROM cur INTO @su, @cant;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        INSERT INTO TP_TRASLADOS (placa, ruta)
        SELECT u.placa, @ruta
        FROM TP_SOLICITUD_UNIDADES su JOIN TP_UNIDADES u ON u.idUnidad = su.idUnidad
        WHERE su.idSolicitudUnidad = @su;
        SET @idTraslado = SCOPE_IDENTITY();
        UPDATE TP_SOLICITUD_UNIDADES SET idTraslado = @idTraslado WHERE idSolicitudUnidad = @su;

        -- Origen = subida, destino = bajada (mismo patron que asignarUnidad)
        INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
        VALUES (@idTraslado, @idPuntoO, @origen, 1, @cant, 0);
        SET @idParada = SCOPE_IDENTITY();
        INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, idSolicitudUnidad, tipo, cantidadPlaneada)
        VALUES (@idParada, @idSolicitud, @su, 'S', @cant);

        IF @origen <> @destino
        BEGIN
            INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
            VALUES (@idTraslado, @idPuntoD, @destino, 2, 0, @cant);
            SET @idParada = SCOPE_IDENTITY();
            INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, idSolicitudUnidad, tipo, cantidadPlaneada)
            VALUES (@idParada, @idSolicitud, @su, 'B', @cant);
        END
        ELSE
            INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, idSolicitudUnidad, tipo, cantidadPlaneada)
            VALUES (@idParada, @idSolicitud, @su, 'B', @cant);

        FETCH NEXT FROM cur INTO @su, @cant;
    END
    CLOSE cur; DEALLOCATE cur;

    UPDATE TP_SOLICITUDES
    SET placa = CASE WHEN (SELECT COUNT(*) FROM OPENJSON(@json, '$.unidades')) = 1
                     THEN JSON_VALUE(@json, '$.unidades[0].placa') ELSE 'MULTIPLE' END,
        estado = 'ASIGNADO'
    WHERE idSolicitud = @idSolicitud;

    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT usr.idUsuario,'Nuevo servicio asignado',CONCAT('Solicitud #',@idSolicitud,' asignada a ',u.placa),'ASIGNACION'
    FROM TP_SOLICITUD_UNIDADES su JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad JOIN TP_USUARIOS usr ON usr.placa=u.placa AND usr.activo=1
    WHERE su.idSolicitud=@idSolicitud;

    INSERT INTO TP_NOTIFICACIONES(idUsuario,titulo,mensaje,tipo)
    SELECT usr.idUsuario,'Solicitud asignada',CONCAT('Su solicitud #',@idSolicitud,' fue asignada a ',u.placa),'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS usr ON usr.usuario=s.usuarioRegistra AND usr.activo=1
    JOIN TP_SOLICITUD_UNIDADES su ON su.idSolicitud=s.idSolicitud JOIN TP_UNIDADES u ON u.idUnidad=su.idUnidad
    WHERE s.idSolicitud=@idSolicitud;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'ASIGNAR_MULTIPLES_UNIDADES', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT su.idSolicitudUnidad, su.idSolicitud, u.idUnidad, u.placa, su.cantidadAsignada, su.estado, su.idTraslado
    FROM TP_SOLICITUD_UNIDADES su JOIN TP_UNIDADES u ON u.idUnidad = su.idUnidad
    WHERE su.idSolicitud = @idSolicitud FOR JSON PATH;
END

