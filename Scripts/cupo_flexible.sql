-- =====================================================================
-- SPs V2: cupo flexible — la capacidad deja de ser bloqueante
--
-- Los SPs originales NO se modifican: se crean versiones *_V2 basadas en
-- las definiciones VIVAS de la BD (con traslado implicito, paradas
-- autogeneradas, estadoOperativo, etc.) y el API las invoca a traves de
-- TransporteRepositoryImpl. Los originales quedan intactos.
--
-- Requerimiento: el coordinador debe poder colocar una placa aunque la
-- unidad ya haya completado su capacidad (la UI pide confirmacion), y el
-- conductor puede agregar pasajeros extra en emergencias. Se QUITA el
-- RAISERROR por falta de cupo; se MANTIENEN el resto de validaciones
-- (unidad activa/operativa, estados, distribucion exacta, paradas, etc.).
-- El cupoDisponible/ocupacion puede quedar negativo = sobreasignado.
--
-- Cada SP V2 incluye ademas el estado A_BORDO donde corresponde.
-- Aplicar junto con estado_abordo.sql (ambos crean sus *_V2).
-- =====================================================================

-- Las tablas TP_* tienen indices filtrados: los SPs DEBEN crearse con
-- QUOTED_IDENTIFIER ON (sin esto, todo UPDATE/INSERT falla con Msg 1934).
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

-- 1) Asignar unidad V2: igual que la version viva (estadoOperativo +
--    traslado implicito + paradas base + detalle) pero SIN el bloqueo
--    de cupo. La confirmacion de sobreasignacion es en la UI.
CREATE OR ALTER PROCEDURE TRANSPORTE_asignarUnidad_V2
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @id INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1 AND estadoOperativo = 'OPERATIVA');
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1 AND estadoOperativo = 'OPERATIVA');
    DECLARE @cantidad INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @id);

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente, inactiva o no operativa', 16, 1); RETURN; END
    IF @cantidad IS NULL BEGIN RAISERROR('Solicitud inexistente', 16, 1); RETURN; END
    IF NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @id AND estado = 'PENDIENTE')
    BEGIN RAISERROR('La solicitud no esta pendiente de asignacion', 16, 1); RETURN; END

    DECLARE @pp NVARCHAR(300), @pl NVARCHAR(300);
    SELECT @pp = puntoPartida, @pl = puntoLlegada FROM TP_SOLICITUDES WHERE idSolicitud = @id;

    -- Traslado implicito (una sola solicitud)
    INSERT INTO TP_TRASLADOS (placa, ruta) VALUES (@placa, CONCAT(@pp, ' > ', @pl));
    DECLARE @idTraslado INT = SCOPE_IDENTITY();

    UPDATE TP_SOLICITUDES
    SET placa = @placa, estado = 'ASIGNADO', idTraslado = @idTraslado
    WHERE idSolicitud = @id;

    -- Paradas base A -> B (si partida = llegada, una sola parada con ambos)
    INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
    SELECT @idTraslado, pt.idPunto, v.punto, v.orden, v.sube, v.baja
    FROM (VALUES (@pp, 1, @cantidad, CASE WHEN @pp = @pl THEN @cantidad ELSE 0 END),
                 (@pl, 2, 0, @cantidad)) v(punto, orden, sube, baja)
    LEFT JOIN TP_PUNTOS pt ON pt.nombre = v.punto AND pt.activo = 1
    WHERE NOT (@pp = @pl AND v.orden = 2);

    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    SELECT p.idParada, @id,
           CASE WHEN p.orden = 1 THEN 'S' ELSE 'B' END, @cantidad
    FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = @idTraslado;
    -- Caso partida = llegada: un solo punto recibe ambos detalles
    IF @pp = @pl
        INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
        SELECT TOP 1 p.idParada, @id, 'B', @cantidad
        FROM TP_TRASLADO_PARADAS p WHERE p.idTraslado = @idTraslado ORDER BY p.orden;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Solicitud #', @id, ' asignada a la unidad ', @placa), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud asignada', CONCAT('Su solicitud #', @id, ' fue asignada a la unidad ', @placa), 'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @id AND u.activo = 1;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @id, 'ASIGNAR_UNIDAD', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @id FOR JSON PATH;
END
GO

-- 2) Unir solicitudes V2: igual que la version viva (paradas fusionadas
--    por punto + detalle por solicitud) pero SIN el bloqueo de cupo.
CREATE OR ALTER PROCEDURE TRANSPORTE_unirSolicitudes_V2
    @json NVARCHAR(MAX)
AS
BEGIN
    DECLARE @placa NVARCHAR(20) = JSON_VALUE(@json, '$.placa');
    DECLARE @idTraslado INT;
    DECLARE @ruta NVARCHAR(1000);
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);

    DECLARE @Ids TABLE (idSolicitud INT, orden INT);
    INSERT INTO @Ids
    SELECT TRY_CAST(j.value AS INT), MIN(TRY_CAST(j.[key] AS INT))
    FROM OPENJSON(@json, '$.ids') j
    GROUP BY TRY_CAST(j.value AS INT);

    DECLARE @totalPersonas INT = (
        SELECT COALESCE(SUM(s.cantidad), 0) FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud);

    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud
               WHERE s.estado <> 'PENDIENTE' OR s.idTraslado IS NOT NULL)
    BEGIN RAISERROR('Solo se pueden unir solicitudes pendientes sin traslado', 16, 1); RETURN; END

    IF (SELECT COUNT(DISTINCT s.fechaProgramada)
        FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud) > 1
    BEGIN RAISERROR('Solo se pueden unir solicitudes de la misma fecha', 16, 1); RETURN; END

    -- Eventos S/B por solicitud: partida antes que llegada (evOrd 0/1)
    DECLARE @Eventos TABLE (solOrd INT, evOrd INT, idSolicitud INT,
                            punto NVARCHAR(300), tipo CHAR(1), cantidad INT);
    INSERT INTO @Eventos
    SELECT i.orden, 0, s.idSolicitud, s.puntoPartida, 'S', s.cantidad
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud;
    INSERT INTO @Eventos
    SELECT i.orden, 1, s.idSolicitud, s.puntoLlegada, 'B', s.cantidad
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud;

    -- Ruta: puntos unicos en orden de primera aparicion
    SELECT @ruta = STUFF((
        SELECT ' > ' + punto FROM (
            SELECT punto, MIN(solOrd * 2 + evOrd) AS posMin
            FROM @Eventos GROUP BY punto) p
        ORDER BY posMin
        FOR XML PATH(''), TYPE).value('.', 'NVARCHAR(MAX)'), 1, 3, '');

    INSERT INTO TP_TRASLADOS (placa, ruta) VALUES (@placa, @ruta);
    SET @idTraslado = SCOPE_IDENTITY();

    -- Paradas fusionadas por punto
    INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
    SELECT @idTraslado, pt.idPunto, pl.punto,
           ROW_NUMBER() OVER (ORDER BY pl.posMin),
           pl.sube, pl.baja
    FROM (SELECT punto, MIN(solOrd * 2 + evOrd) AS posMin,
                 ISNULL(SUM(CASE WHEN tipo = 'S' THEN cantidad END), 0) AS sube,
                 ISNULL(SUM(CASE WHEN tipo = 'B' THEN cantidad END), 0) AS baja
          FROM @Eventos GROUP BY punto) pl
    LEFT JOIN TP_PUNTOS pt ON pt.nombre = pl.punto AND pt.activo = 1;

    -- Detalle parada <-> solicitud
    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    SELECT p.idParada, e.idSolicitud, e.tipo, e.cantidad
    FROM @Eventos e
    JOIN TP_TRASLADO_PARADAS p ON p.idTraslado = @idTraslado AND p.punto = e.punto;

    UPDATE s
    SET s.idTraslado = @idTraslado, s.placa = @placa, s.estado = 'ASIGNADO'
    FROM TP_SOLICITUDES s JOIN @Ids i ON s.idSolicitud = i.idSolicitud;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Traslado T-', @idTraslado, ' asignado a la unidad ', @placa), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Solicitud asignada', CONCAT('Su solicitud #', s.idSolicitud, ' se unio al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idTraslado = @idTraslado AND u.activo = 1;

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('TRASLADO', @idTraslado, 'UNIR_SOLICITUDES', JSON_VALUE(@json, '$.usuario'), @json);

    SELECT t.idTraslado, t.placa, t.ruta, t.estado
    FROM TP_TRASLADOS t WHERE t.idTraslado = @idTraslado
    FOR JSON PATH;
END
GO

-- 3) Asignar multiples V2: igual que la version viva (disuelve traslados
--    previos, traslado implicito por porcion, estadoOperativo) pero SIN
--    el bloqueo de cupo por unidad. A_BORDO cuenta como "en curso".
CREATE OR ALTER PROCEDURE TRANSPORTE_asignarMultiplesUnidades_V2
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @requerido INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud);
    DECLARE @asignado INT;

    SELECT @asignado = SUM(TRY_CAST(JSON_VALUE(value, '$.cantidad') AS INT)) FROM OPENJSON(@json, '$.unidades');

    IF @requerido IS NULL OR @asignado <> @requerido
    BEGIN RAISERROR(N'La distribucion debe cubrir exactamente la cantidad solicitada', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud AND estado IN ('EN_RUTA', 'A_BORDO', 'REALIZADO', 'ANULADO'))
    BEGIN RAISERROR('La solicitud ya esta en curso, realizada o anulada', 16, 1); RETURN; END

    -- Una placa no puede repetirse en la distribucion
    IF EXISTS (SELECT 1 FROM OPENJSON(@json, '$.unidades') j
               GROUP BY JSON_VALUE(j.value, '$.placa') HAVING COUNT(*) > 1)
    BEGIN RAISERROR('No se puede repetir la misma unidad en la distribucion', 16, 1); RETURN; END

    -- Cada unidad debe existir, estar activa y en estadoOperativo='OPERATIVA'
    IF EXISTS (
        SELECT 1
        FROM OPENJSON(@json, '$.unidades') j
        LEFT JOIN TP_UNIDADES u ON u.placa = JSON_VALUE(j.value, '$.placa') AND u.activa = 1 AND u.estadoOperativo = 'OPERATIVA'
        WHERE u.idUnidad IS NULL
    )
    BEGIN RAISERROR('Una unidad no existe, no esta activa o no esta operativa', 16, 1); RETURN; END

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
GO

-- 4) Acoplar solicitud V2: igual que la version viva (guarda de area,
--    bloqueo si el traslado ya inicio, fusión de paradas, compatibilidad
--    geografica) pero SIN el bloqueo de cupo.
CREATE OR ALTER PROCEDURE TRANSPORTE_acoplarSolicitud_V2
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idTraslado INT = TRY_CAST(JSON_VALUE(@json, '$.idTraslado') AS INT);
    DECLARE @usuario NVARCHAR(50) = JSON_VALUE(@json, '$.usuario');
    DECLARE @placa NVARCHAR(20) = (SELECT placa FROM TP_TRASLADOS WHERE idTraslado = @idTraslado AND estado <> 'ANULADO');
    DECLARE @cantidad INT = (SELECT cantidad FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud AND estado = 'PENDIENTE');
    IF @placa IS NULL OR @cantidad IS NULL BEGIN RAISERROR('Solicitud o traslado no disponible', 16, 1); RETURN; END

    IF EXISTS (SELECT 1 FROM TP_USUARIOS WHERE usuario = @usuario AND idrol = 'SPTRANS')
       AND NOT EXISTS (SELECT 1 FROM TP_SOLICITUDES s
                       JOIN TP_USUARIOS u ON u.usuario = @usuario AND u.idArea = s.idArea
                       WHERE s.idSolicitud = @idSolicitud)
    BEGIN RAISERROR('Solo puede acoplar solicitudes de su propia area', 16, 1); RETURN; END

    -- La ruta no debe estar en ejecucion para modificar sus paradas
    IF EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS
               WHERE idTraslado = @idTraslado AND estado <> 'PENDIENTE')
    BEGIN RAISERROR('El traslado ya inicio su recorrido', 16, 1); RETURN; END

    -- Compatibilidad geografica: origen y destino a <= 10 km de la ruta
    DECLARE @maxKm FLOAT = 10;
    DECLARE @latP DECIMAL(9,6), @lonP DECIMAL(9,6), @latL DECIMAL(9,6), @lonL DECIMAL(9,6);
    SELECT @latP = p.latitud, @lonP = p.longitud
    FROM TP_SOLICITUDES s JOIN TP_PUNTOS p ON p.nombre = s.puntoPartida AND p.activo = 1
    WHERE s.idSolicitud = @idSolicitud;
    SELECT @latL = p.latitud, @lonL = p.longitud
    FROM TP_SOLICITUDES s JOIN TP_PUNTOS p ON p.nombre = s.puntoLlegada AND p.activo = 1
    WHERE s.idSolicitud = @idSolicitud;

    IF OBJECT_ID('tempdb..#RUTA') IS NOT NULL DROP TABLE #RUTA;
    CREATE TABLE #RUTA (latitud DECIMAL(9,6), longitud DECIMAL(9,6));
    INSERT INTO #RUTA
        SELECT DISTINCT pt.latitud, pt.longitud
        FROM TP_TRASLADO_PARADAS pa JOIN TP_PUNTOS pt ON pt.nombre = pa.punto AND pt.activo = 1
        WHERE pa.idTraslado = @idTraslado AND pt.latitud IS NOT NULL AND pt.longitud IS NOT NULL;
    IF NOT EXISTS (SELECT 1 FROM #RUTA)
        INSERT INTO #RUTA
            SELECT DISTINCT pt.latitud, pt.longitud
            FROM TP_SOLICITUDES s JOIN TP_PUNTOS pt ON pt.activo = 1
                AND (pt.nombre = s.puntoPartida OR pt.nombre = s.puntoLlegada)
            WHERE s.idTraslado = @idTraslado AND pt.latitud IS NOT NULL AND pt.longitud IS NOT NULL;

    IF EXISTS (SELECT 1 FROM #RUTA) AND (@latP IS NOT NULL OR @latL IS NOT NULL)
    BEGIN
        IF @latP IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM #RUTA r
            WHERE 6371 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(r.latitud - @latP) / 2.0), 2) +
                COS(RADIANS(@latP)) * COS(RADIANS(r.latitud)) *
                POWER(SIN(RADIANS(r.longitud - @lonP) / 2.0), 2))) <= @maxKm)
        BEGIN RAISERROR(N'El punto de partida esta a mas de 10 km de la ruta del traslado', 16, 1); RETURN; END

        IF @latL IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM #RUTA r
            WHERE 6371 * 2 * ASIN(SQRT(
                POWER(SIN(RADIANS(r.latitud - @latL) / 2.0), 2) +
                COS(RADIANS(@latL)) * COS(RADIANS(r.latitud)) *
                POWER(SIN(RADIANS(r.longitud - @lonL) / 2.0), 2))) <= @maxKm)
        BEGIN RAISERROR(N'El punto de llegada esta a mas de 10 km de la ruta del traslado', 16, 1); RETURN; END
    END
    DROP TABLE #RUTA;

    UPDATE TP_SOLICITUDES SET idTraslado = @idTraslado, placa = @placa, estado = 'ASIGNADO' WHERE idSolicitud = @idSolicitud;

    -- Fusionar puntos de la solicitud con las paradas pendientes
    DECLARE @pp NVARCHAR(300), @pl2 NVARCHAR(300), @maxOrden INT, @idParadaP INT;
    SELECT @pp = puntoPartida, @pl2 = puntoLlegada FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud;
    SELECT @maxOrden = ISNULL(MAX(orden), 0) FROM TP_TRASLADO_PARADAS WHERE idTraslado = @idTraslado;

    -- Punto de partida (suben)
    SELECT @idParadaP = MIN(idParada) FROM TP_TRASLADO_PARADAS
    WHERE idTraslado = @idTraslado AND punto = @pp AND estado = 'PENDIENTE';
    IF @idParadaP IS NULL
    BEGIN
        SET @maxOrden = @maxOrden + 1;
        INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
        SELECT @idTraslado, pt.idPunto, @pp, @maxOrden, @cantidad, 0
        FROM TP_PUNTOS pt WHERE pt.nombre = @pp AND pt.activo = 1;
        IF @@ROWCOUNT = 0
            INSERT INTO TP_TRASLADO_PARADAS (idTraslado, punto, orden, cantidadSube, cantidadBaja)
            VALUES (@idTraslado, @pp, @maxOrden, @cantidad, 0);
        SET @idParadaP = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE TP_TRASLADO_PARADAS SET cantidadSube = cantidadSube + @cantidad WHERE idParada = @idParadaP;

    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    VALUES (@idParadaP, @idSolicitud, 'S', @cantidad);

    -- Punto de llegada (bajan)
    SET @idParadaP = NULL;
    SELECT @idParadaP = MIN(idParada) FROM TP_TRASLADO_PARADAS
    WHERE idTraslado = @idTraslado AND punto = @pl2 AND estado = 'PENDIENTE';
    IF @idParadaP IS NULL
    BEGIN
        SET @maxOrden = @maxOrden + 1;
        INSERT INTO TP_TRASLADO_PARADAS (idTraslado, idPunto, punto, orden, cantidadSube, cantidadBaja)
        SELECT @idTraslado, pt.idPunto, @pl2, @maxOrden, 0, @cantidad
        FROM TP_PUNTOS pt WHERE pt.nombre = @pl2 AND pt.activo = 1;
        IF @@ROWCOUNT = 0
            INSERT INTO TP_TRASLADO_PARADAS (idTraslado, punto, orden, cantidadSube, cantidadBaja)
            VALUES (@idTraslado, @pl2, @maxOrden, 0, @cantidad);
        SET @idParadaP = SCOPE_IDENTITY();
    END
    ELSE
        UPDATE TP_TRASLADO_PARADAS SET cantidadBaja = cantidadBaja + @cantidad WHERE idParada = @idParadaP;

    INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, tipo, cantidadPlaneada)
    VALUES (@idParadaP, @idSolicitud, 'B', @cantidad);

    -- Recalcular la ruta textual
    DECLARE @ruta NVARCHAR(2000);
    SELECT @ruta = STUFF((SELECT ' > ' + punto FROM TP_TRASLADO_PARADAS
                          WHERE idTraslado = @idTraslado ORDER BY orden
                          FOR XML PATH(''),TYPE).value('.','NVARCHAR(MAX)'),1,3,'');
    UPDATE TP_TRASLADOS SET ruta = @ruta WHERE idTraslado = @idTraslado;

    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT idUsuario, 'Nuevo servicio asignado', CONCAT('Solicitud #', @idSolicitud, ' se acoplo al traslado T-', @idTraslado, ' (', @placa, ')'), 'ASIGNACION'
    FROM TP_USUARIOS WHERE placa = @placa AND activo = 1;
    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'ACOPLAR', JSON_VALUE(@json, '$.usuario'), @json);
    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO

-- 5) Agregar pasajeros V2: igual que la version viva (estadoOperativo
--    implicito via placa activa, registro del extra en la parada actual
--    via idParada) pero SIN el bloqueo de cupo y aceptando A_BORDO.
CREATE OR ALTER PROCEDURE TRANSPORTE_agregarPasajeros_V2
    @json NVARCHAR(MAX)
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @idSolicitud INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitud') AS INT);
    DECLARE @idSolicitudUnidad INT = TRY_CAST(JSON_VALUE(@json, '$.idSolicitudUnidad') AS INT);
    DECLARE @idParada INT = TRY_CAST(JSON_VALUE(@json, '$.idParada') AS INT);
    DECLARE @extra INT = TRY_CAST(JSON_VALUE(@json, '$.cantidad') AS INT);

    IF @extra IS NULL OR @extra < 1 BEGIN RAISERROR(N'Cantidad de pasajeros invalida', 16, 1); RETURN; END

    DECLARE @idUnidad INT = (SELECT idUnidad FROM TP_SOLICITUD_UNIDADES
                             WHERE idSolicitudUnidad = @idSolicitudUnidad AND idSolicitud = @idSolicitud);
    DECLARE @placa NVARCHAR(20) = COALESCE((SELECT placa FROM TP_UNIDADES WHERE idUnidad = @idUnidad),
                                           (SELECT placa FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud));
    DECLARE @estado NVARCHAR(20) = COALESCE((SELECT estado FROM TP_SOLICITUD_UNIDADES WHERE idSolicitudUnidad = @idSolicitudUnidad),
                                            (SELECT estado FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud));
    DECLARE @capacidad INT = (SELECT capacidad FROM TP_UNIDADES WHERE placa = @placa AND activa = 1);

    IF @placa IS NULL OR @placa = 'MULTIPLE' AND @idUnidad IS NULL
    BEGIN RAISERROR('Servicio sin unidad asignada', 16, 1); RETURN; END
    IF @estado IS NULL OR @estado NOT IN ('ASIGNADO', 'EN_RUTA', 'A_BORDO')
    BEGIN RAISERROR('Solo se pueden agregar pasajeros a servicios asignados, en ruta o a bordo', 16, 1); RETURN; END
    IF @capacidad IS NULL BEGIN RAISERROR('Unidad inexistente o inactiva', 16, 1); RETURN; END

    IF @idUnidad IS NOT NULL
        UPDATE TP_SOLICITUD_UNIDADES SET cantidadAsignada = cantidadAsignada + @extra, esEmergencia = 1
        WHERE idSolicitudUnidad = @idSolicitudUnidad;
    ELSE
        UPDATE TP_SOLICITUDES SET esEmergencia = 1, prioridad = 'EMERGENCIA' WHERE idSolicitud = @idSolicitud;
    UPDATE TP_SOLICITUDES SET cantidad = cantidad + @extra WHERE idSolicitud = @idSolicitud;

    -- Si el extra sube en una parada concreta, quedar registrado ahi
    IF @idParada IS NOT NULL
    BEGIN
        UPDATE TP_TRASLADO_PARADAS
        SET cantidadSube  = CASE WHEN estado = 'PENDIENTE' THEN cantidadSube + @extra ELSE cantidadSube END,
            subieronReal  = CASE WHEN estado = 'EN_PARADA' THEN COALESCE(subieronReal, cantidadSube, 0) + @extra ELSE subieronReal END
        WHERE idParada = @idParada AND estado IN ('PENDIENTE','EN_PARADA');

        IF EXISTS (SELECT 1 FROM TP_PARADA_DETALLE
                   WHERE idParada = @idParada AND idSolicitud = @idSolicitud AND tipo = 'S'
                     AND (idSolicitudUnidad = @idSolicitudUnidad OR (@idSolicitudUnidad IS NULL AND idSolicitudUnidad IS NULL)))
            UPDATE TP_PARADA_DETALLE
            SET cantidadPlaneada = cantidadPlaneada + @extra,
                cantidadReal = CASE WHEN cantidadReal IS NOT NULL THEN cantidadReal + @extra ELSE cantidadReal END
            WHERE idParada = @idParada AND idSolicitud = @idSolicitud AND tipo = 'S'
              AND (idSolicitudUnidad = @idSolicitudUnidad OR (@idSolicitudUnidad IS NULL AND idSolicitudUnidad IS NULL));
        ELSE IF EXISTS (SELECT 1 FROM TP_TRASLADO_PARADAS WHERE idParada = @idParada)
            INSERT INTO TP_PARADA_DETALLE (idParada, idSolicitud, idSolicitudUnidad, tipo, cantidadPlaneada)
            VALUES (@idParada, @idSolicitud, @idSolicitudUnidad, 'S', @extra);
    END

    INSERT INTO TP_AUDITORIA(entidad, idEntidad, accion, usuario, detalle)
    VALUES ('SOLICITUD', @idSolicitud, 'AGREGAR_PASAJEROS', JSON_VALUE(@json, '$.usuario'), @json);
    INSERT INTO TP_NOTIFICACIONES(idUsuario, titulo, mensaje, tipo)
    SELECT u.idUsuario, 'Pasajeros agregados', CONCAT(N'El conductor agrego ', @extra, ' pasajero(s) a la solicitud #', @idSolicitud), 'PASAJEROS'
    FROM TP_SOLICITUDES s JOIN TP_USUARIOS u ON u.usuario = s.usuarioRegistra
    WHERE s.idSolicitud = @idSolicitud AND u.activo = 1;

    SELECT * FROM TP_SOLICITUDES WHERE idSolicitud = @idSolicitud FOR JSON PATH;
END
GO
