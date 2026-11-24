/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 03 : CONFIGURACION DE LOS LINKED SERVERS (uno por nodo)

     Linked Server   Base de datos    Nodo
     -------------   --------------   ---------------------------------
     SRV_CENTRAL     BancoCentral     Base principal (sede central)
     SRV_MEDELLIN    BancoMedellin    Sucursal Medellín (sede central)
     SRV_BOGOTA      BancoBogota      Sucursal Bogotá
     SRV_CARTAGENA   BancoCartagena   Sucursal Cartagena
     SRV_SANANDRES   BancoSanAndres   Sucursal San Andrés
     SRV_CALI        BancoCali        Sucursal Cali

   Los Linked Servers se definen a nivel de INSTANCIA: cualquier nodo
   puede consultar a cualquier otro (malla completa entre sucursales),
   por ejemplo desde BancoCali:  SELECT * FROM SRV_BOGOTA.BancoBogota.dbo.Empleados
   Simulacion: todos apuntan a la MISMA instancia (loopback) y se usan
   con nombres de 4 partes, OPENQUERY y RPC como si fueran otros servidores.
   ===================================================================== */
USE master;
GO

DECLARE @nodos TABLE (srv SYSNAME PRIMARY KEY, bd SYSNAME);
INSERT INTO @nodos VALUES
(N'SRV_CENTRAL',   N'BancoCentral'),
(N'SRV_MEDELLIN',  N'BancoMedellin'),
(N'SRV_BOGOTA',    N'BancoBogota'),
(N'SRV_CARTAGENA', N'BancoCartagena'),
(N'SRV_SANANDRES', N'BancoSanAndres'),
(N'SRV_CALI',      N'BancoCali');

-- 1. Detectar el proveedor OLE DB disponible (2022+ trae MSOLEDBSQL19,
--    2019 trae MSOLEDBSQL, versiones antiguas SQLNCLI11)
DECLARE @proveedores TABLE (nombre NVARCHAR(255), parse_name NVARCHAR(255), descripcion NVARCHAR(255));
BEGIN TRY
    INSERT INTO @proveedores EXEC master.dbo.xp_enum_oledb_providers;
END TRY
BEGIN CATCH
    INSERT INTO @proveedores (nombre) VALUES (N'MSOLEDBSQL');
END CATCH;

DECLARE @proveedor NVARCHAR(128) =
    CASE WHEN EXISTS (SELECT 1 FROM @proveedores WHERE nombre = N'MSOLEDBSQL19') THEN N'MSOLEDBSQL19'
         WHEN EXISTS (SELECT 1 FROM @proveedores WHERE nombre = N'MSOLEDBSQL')   THEN N'MSOLEDBSQL'
         ELSE N'SQLNCLI11' END;

-- 2. Nombre real de la instancia actual (EQUIPO o EQUIPO\INSTANCIA)
DECLARE @instancia NVARCHAR(128) = CAST(SERVERPROPERTY('ServerName') AS NVARCHAR(128));
PRINT N'Proveedor OLE DB : ' + @proveedor;
PRINT N'Instancia destino: ' + @instancia;

-- 3. Crear (o recrear) cada Linked Server
DECLARE @srv SYSNAME, @bd SYSNAME;
DECLARE c CURSOR LOCAL FAST_FORWARD FOR SELECT srv, bd FROM @nodos;
OPEN c;
FETCH NEXT FROM c INTO @srv, @bd;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF EXISTS (SELECT 1 FROM sys.servers WHERE name = @srv)
        EXEC master.dbo.sp_dropserver @server = @srv, @droplogins = 'droplogins';

    EXEC master.dbo.sp_addlinkedserver
         @server     = @srv,
         @srvproduct = N'',
         @provider   = @proveedor,
         @datasrc    = @instancia,
         @provstr    = N'TrustServerCertificate=yes;',
         @catalog    = @bd;

    -- Seguridad: usar las mismas credenciales del usuario que se conecta
    EXEC master.dbo.sp_addlinkedsrvlogin @rmtsrvname = @srv, @useself = N'True', @locallogin = NULL;

    -- Opciones del servidor vinculado
    EXEC master.dbo.sp_serveroption @server = @srv, @optname = N'data access', @optvalue = N'true';  -- consultas
    EXEC master.dbo.sp_serveroption @server = @srv, @optname = N'rpc',         @optvalue = N'true';  -- llamadas entrantes
    EXEC master.dbo.sp_serveroption @server = @srv, @optname = N'rpc out',     @optvalue = N'true';  -- ejecutar SP remotos
    EXEC master.dbo.sp_serveroption @server = @srv, @optname = N'remote proc transaction promotion', @optvalue = N'false'; -- sin MSDTC

    -- Probar la conexion (si falla, lanza error)
    EXEC master.dbo.sp_testlinkedserver @srv;
    PRINT N'>> Linked Server ' + @srv + N' -> ' + @bd + N' verificado.';

    FETCH NEXT FROM c INTO @srv, @bd;
END
CLOSE c; DEALLOCATE c;
GO

/* ---------------------------------------------------------------------
   4. EVIDENCIA DE FUNCIONAMIENTO DE LOS LINKED SERVERS
   --------------------------------------------------------------------- */
-- 4.1 Configuracion registrada
SELECT name AS linked_server, provider, data_source, catalog,
       is_data_access_enabled, is_rpc_out_enabled
FROM sys.servers
WHERE is_linked = 1 AND name LIKE N'SRV[_]%'
ORDER BY server_id;
GO

-- 4.2 Consulta con nombres de 4 partes a cada sucursal (reconstruye la tabla global)
SELECT * FROM SRV_MEDELLIN.BancoMedellin.dbo.Sucursales
UNION ALL SELECT * FROM SRV_BOGOTA.BancoBogota.dbo.Sucursales
UNION ALL SELECT * FROM SRV_CARTAGENA.BancoCartagena.dbo.Sucursales
UNION ALL SELECT * FROM SRV_SANANDRES.BancoSanAndres.dbo.Sucursales
UNION ALL SELECT * FROM SRV_CALI.BancoCali.dbo.Sucursales;
GO

-- 4.3 OPENQUERY (la consulta se ejecuta en el nodo remoto)
SELECT * FROM OPENQUERY(SRV_BOGOTA, 'SELECT id_tipo_cuenta, nombre FROM BancoBogota.dbo.TiposCuenta');
GO

-- 4.4 Procedimiento remoto (RPC) en un nodo de sucursal
EXEC SRV_CARTAGENA.BancoCartagena.dbo.sp_Sucursal_Consultar;
GO

-- 4.5 Comunicacion ENTRE SUCURSALES (sin pasar por la sede central):
--     el nodo de Cali consulta los empleados del nodo de Bogotá
USE BancoCali;
GO
SELECT N'Consulta desde BancoCali' AS origen, e.*
FROM SRV_BOGOTA.BancoBogota.dbo.Empleados e;
GO
USE master;
GO
