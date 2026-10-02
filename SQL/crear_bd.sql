-- ============================================
-- TRANSPORTE DE PERSONAL - CREAR BASE DE DATOS
-- Ejecutar primero en el servidor SQL Server
-- ============================================

IF NOT EXISTS (SELECT name FROM sys.databases WHERE name = 'TRANSPORTE_PERSONAL')
BEGIN
    CREATE DATABASE [TRANSPORTE_PERSONAL]
        COLLATE Latin1_General_CI_AS;
    PRINT 'Base de datos TRANSPORTE_PERSONAL creada correctamente.';
END
ELSE
BEGIN
    PRINT 'La base de datos TRANSPORTE_PERSONAL ya existe.';
END
GO
