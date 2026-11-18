/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 03 : CONFIGURACION DEL LINKED SERVER  ->  SRV_REMOTO
   Simulacion: el Linked Server apunta a la MISMA instancia (loopback),
               pero se consulta como si fuera otro servidor, usando
               nombres de 4 partes: SRV_REMOTO.BancoRemoto.dbo.Tabla
   ===================================================================== */
USE master;
GO

-- 1. Eliminar el linked server si ya existe (permite re-ejecutar el script)
IF EXISTS (SELECT 1 FROM sys.servers WHERE name = N'SRV_REMOTO')
    EXEC master.dbo.sp_dropserver @server = N'SRV_REMOTO', @droplogins = 'droplogins';
GO

-- 2. Detectar el proveedor OLE DB disponible (SQL Server 2022 trae MSOLEDBSQL19,
--    2019 trae MSOLEDBSQL, versiones antiguas SQLNCLI11)
DECLARE @proveedores TABLE (nombre NVARCHAR(255), parse_name NVARCHAR(255), descripcion NVARCHAR(255));
BEGIN TRY
    INSERT INTO @proveedores EXEC master.dbo.xp_enum_oledb_providers;
END TRY
BEGIN CATCH
    INSERT INTO @proveedores (nombre) VALUES (N'MSOLEDBSQL');   -- si no se puede enumerar, usar MSOLEDBSQL
END CATCH;

DECLARE @proveedor NVARCHAR(128) =
    CASE WHEN EXISTS (SELECT 1 FROM @proveedores WHERE nombre = N'MSOLEDBSQL19') THEN N'MSOLEDBSQL19'
         WHEN EXISTS (SELECT 1 FROM @proveedores WHERE nombre = N'MSOLEDBSQL')   THEN N'MSOLEDBSQL'
         ELSE N'SQLNCLI11' END;

-- 3. Nombre real de la instancia actual (EQUIPO o EQUIPO\INSTANCIA)
DECLARE @instancia NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));

PRINT N'Proveedor OLE DB : ' + @proveedor;
PRINT N'Instancia destino: ' + @instancia;

-- 4. Crear el Linked Server
EXEC master.dbo.sp_addlinkedserver
     @server     = N'SRV_REMOTO',
     @srvproduct = N'',
     @provider   = @proveedor,
     @datasrc    = @instancia,
     @provstr    = N'TrustServerCertificate=yes;',
     @catalog    = N'BancoRemoto';
GO

-- 5. Seguridad: usar las mismas credenciales del usuario que se conecta
EXEC master.dbo.sp_addlinkedsrvlogin
     @rmtsrvname = N'SRV_REMOTO',
     @useself    = N'True',
     @locallogin = NULL;
GO

-- 6. Opciones del servidor vinculado
EXEC master.dbo.sp_serveroption @server = N'SRV_REMOTO', @optname = N'data access', @optvalue = N'true';  -- consultas
EXEC master.dbo.sp_serveroption @server = N'SRV_REMOTO', @optname = N'rpc',         @optvalue = N'true';  -- llamadas entrantes
EXEC master.dbo.sp_serveroption @server = N'SRV_REMOTO', @optname = N'rpc out',     @optvalue = N'true';  -- ejecutar SP remotos
EXEC master.dbo.sp_serveroption @server = N'SRV_REMOTO', @optname = N'remote proc transaction promotion', @optvalue = N'false'; -- sin MSDTC
GO

/* ---------------------------------------------------------------------
   7. EVIDENCIA DE FUNCIONAMIENTO DEL LINKED SERVER
   --------------------------------------------------------------------- */
-- 7.1 Probar la conexion (si falla, lanza error)
EXEC master.dbo.sp_testlinkedserver N'SRV_REMOTO';
PRINT N'>> Conexión con SRV_REMOTO verificada.';
GO

-- 7.2 Ver la configuracion registrada
SELECT name AS linked_server, product, provider, data_source, catalog,
       is_data_access_enabled, is_rpc_out_enabled
FROM sys.servers
WHERE name = N'SRV_REMOTO';
GO

-- 7.3 Consulta con nombre de 4 partes
SELECT * FROM SRV_REMOTO.BancoRemoto.dbo.Sucursales;
GO

-- 7.4 Consulta con OPENQUERY (la consulta se ejecuta en el servidor remoto)
SELECT * FROM OPENQUERY(SRV_REMOTO, 'SELECT id_tipo_cuenta, nombre FROM BancoRemoto.dbo.TiposCuenta');
GO

-- 7.5 Ejecucion de un procedimiento remoto (RPC)
EXEC SRV_REMOTO.BancoRemoto.dbo.sp_Sucursal_Consultar;
GO
