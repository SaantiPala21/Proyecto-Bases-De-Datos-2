/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 02 : BASE DE DATOS PRINCIPAL (Sede Central Medellin) -> BancoCentral
   Contiene  : Clientes, Cuentas, Transacciones, Prestamos, Pagos
               + indices + directorio de nodos + sinonimos hacia los
               5 nodos de sucursal + vistas de reconstruccion.
   Requisito : haber ejecutado 01_BD_Remotas_Sucursales.sql
   ===================================================================== */
USE master;
GO

IF DB_ID(N'BancoCentral') IS NOT NULL
BEGIN
    ALTER DATABASE BancoCentral SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoCentral;
END
GO
CREATE DATABASE BancoCentral;
GO
USE BancoCentral;
GO

/* ---------------------------------------------------------------------
   1. TABLAS
   --------------------------------------------------------------------- */
CREATE TABLE dbo.Clientes
(
    id_cliente     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Clientes PRIMARY KEY,
    nombre         NVARCHAR(100) NOT NULL,
    documento      VARCHAR(20)   NOT NULL CONSTRAINT UQ_Clientes_documento UNIQUE,
    direccion      NVARCHAR(150) NULL,
    telefono       VARCHAR(20)   NULL,
    tipo_cliente   VARCHAR(10)   NOT NULL CONSTRAINT CK_Clientes_tipo   CHECK (tipo_cliente IN ('NATURAL','JURIDICO')),
    estado         VARCHAR(10)   NOT NULL CONSTRAINT DF_Clientes_estado DEFAULT ('ACTIVO')
                                          CONSTRAINT CK_Clientes_estado CHECK (estado IN ('ACTIVO','INACTIVO')),
    fecha_registro DATETIME2(0)  NOT NULL CONSTRAINT DF_Clientes_fecha  DEFAULT (SYSDATETIME())
);
GO

CREATE TABLE dbo.Cuentas
(
    id_cuenta      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Cuentas PRIMARY KEY,
    numero_cuenta  VARCHAR(20)   NOT NULL CONSTRAINT UQ_Cuentas_numero UNIQUE,
    id_cliente     INT           NOT NULL CONSTRAINT FK_Cuentas_Clientes REFERENCES dbo.Clientes(id_cliente),
    id_tipo_cuenta INT           NOT NULL,   -- referencia REMOTA: TiposCuenta (catalogo replicado en los nodos)
    id_sucursal    INT           NOT NULL,   -- referencia REMOTA: Sucursales del nodo de la ciudad (validada por trigger)
    saldo          DECIMAL(18,2) NOT NULL CONSTRAINT DF_Cuentas_saldo DEFAULT (0)
                                          CONSTRAINT CK_Cuentas_saldo CHECK (saldo >= 0),   -- nunca saldo negativo
    estado         VARCHAR(10)   NOT NULL CONSTRAINT DF_Cuentas_estado DEFAULT ('ACTIVA')
                                          CONSTRAINT CK_Cuentas_estado CHECK (estado IN ('ACTIVA','INACTIVA','BLOQUEADA','CERRADA')),
    fecha_apertura DATETIME2(0)  NOT NULL CONSTRAINT DF_Cuentas_fecha DEFAULT (SYSDATETIME())
);
GO

CREATE TABLE dbo.Transacciones
(
    id_transaccion    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Transacciones PRIMARY KEY,
    id_cuenta         INT           NOT NULL CONSTRAINT FK_Transacciones_Cuenta  REFERENCES dbo.Cuentas(id_cuenta),
    tipo              VARCHAR(15)   NOT NULL CONSTRAINT CK_Transacciones_tipo  CHECK (tipo IN ('DEPOSITO','RETIRO','TRANSFERENCIA')),
    monto             DECIMAL(18,2) NOT NULL CONSTRAINT CK_Transacciones_monto CHECK (monto > 0),
    fecha             DATETIME2(0)  NOT NULL CONSTRAINT DF_Transacciones_fecha DEFAULT (SYSDATETIME()),
    id_cuenta_destino INT           NULL     CONSTRAINT FK_Transacciones_Destino REFERENCES dbo.Cuentas(id_cuenta),
    descripcion       NVARCHAR(200) NULL,
    -- Una transferencia SIEMPRE tiene cuenta destino (distinta a la origen); depositos y retiros NO
    CONSTRAINT CK_Transacciones_destino CHECK (
        (tipo = 'TRANSFERENCIA' AND id_cuenta_destino IS NOT NULL AND id_cuenta_destino <> id_cuenta)
     OR (tipo <> 'TRANSFERENCIA' AND id_cuenta_destino IS NULL))
);
GO

CREATE TABLE dbo.Prestamos
(
    id_prestamo      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Prestamos PRIMARY KEY,
    id_cliente       INT           NOT NULL CONSTRAINT FK_Prestamos_Clientes REFERENCES dbo.Clientes(id_cliente),
    id_producto      INT           NULL,     -- referencia REMOTA: ProductosFinancieros (catalogo replicado)
    monto            DECIMAL(18,2) NOT NULL CONSTRAINT CK_Prestamos_monto   CHECK (monto > 0),
    interes          DECIMAL(5,2)  NOT NULL CONSTRAINT CK_Prestamos_interes CHECK (interes BETWEEN 0 AND 100), -- % anual
    plazo            INT           NOT NULL CONSTRAINT CK_Prestamos_plazo   CHECK (plazo BETWEEN 1 AND 360),   -- meses
    saldo_pendiente  DECIMAL(18,2) NOT NULL CONSTRAINT DF_Prestamos_saldo   DEFAULT (0)
                                            CONSTRAINT CK_Prestamos_saldo   CHECK (saldo_pendiente >= 0),
    estado           VARCHAR(10)   NOT NULL CONSTRAINT DF_Prestamos_estado  DEFAULT ('ACTIVO')
                                            CONSTRAINT CK_Prestamos_estado  CHECK (estado IN ('ACTIVO','MORA','PAGADO','CANCELADO')),
    fecha_desembolso DATETIME2(0)  NOT NULL CONSTRAINT DF_Prestamos_fecha   DEFAULT (SYSDATETIME())
);
GO

CREATE TABLE dbo.Pagos
(
    id_pago     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Pagos PRIMARY KEY,
    id_prestamo INT           NOT NULL CONSTRAINT FK_Pagos_Prestamos REFERENCES dbo.Prestamos(id_prestamo),
    monto       DECIMAL(18,2) NOT NULL CONSTRAINT CK_Pagos_monto CHECK (monto > 0),
    fecha       DATETIME2(0)  NOT NULL CONSTRAINT DF_Pagos_fecha DEFAULT (SYSDATETIME())
);
GO

/* ---------------------------------------------------------------------
   2. INDICES DE APOYO (claves foraneas y consultas frecuentes)
   --------------------------------------------------------------------- */
CREATE INDEX IX_Cuentas_cliente          ON dbo.Cuentas(id_cliente);
CREATE INDEX IX_Cuentas_sucursal         ON dbo.Cuentas(id_sucursal);
CREATE INDEX IX_Transacciones_cuenta     ON dbo.Transacciones(id_cuenta, fecha) INCLUDE (tipo, monto);
CREATE INDEX IX_Transacciones_destino    ON dbo.Transacciones(id_cuenta_destino) WHERE id_cuenta_destino IS NOT NULL;
CREATE INDEX IX_Prestamos_cliente        ON dbo.Prestamos(id_cliente, estado);
CREATE INDEX IX_Pagos_prestamo           ON dbo.Pagos(id_prestamo, fecha);
GO

/* ---------------------------------------------------------------------
   3. DIRECTORIO DE NODOS (la sede central gestiona todas las sedes)
   Indica en que base de datos y en que Linked Server vive cada sucursal.
   Lo usan los procedimientos sp_Dist_* para enrutar operaciones.
   --------------------------------------------------------------------- */
CREATE TABLE dbo.Nodos
(
    id_nodo         INT           NOT NULL CONSTRAINT PK_Nodos PRIMARY KEY,   -- = id de la sucursal principal
    ciudad          NVARCHAR(50)  NOT NULL CONSTRAINT UQ_Nodos_ciudad UNIQUE,
    base_datos      SYSNAME       NOT NULL CONSTRAINT UQ_Nodos_bd UNIQUE,
    linked_server   SYSNAME       NOT NULL CONSTRAINT UQ_Nodos_srv UNIQUE,
    es_sede_central BIT           NOT NULL CONSTRAINT DF_Nodos_central DEFAULT (0)
);
GO
INSERT INTO dbo.Nodos (id_nodo, ciudad, base_datos, linked_server, es_sede_central) VALUES
(1, N'Medellín',   N'BancoMedellin',  N'SRV_MEDELLIN',  1),
(2, N'Bogotá',     N'BancoBogota',    N'SRV_BOGOTA',    0),
(3, N'Cartagena',  N'BancoCartagena', N'SRV_CARTAGENA', 0),
(4, N'San Andrés', N'BancoSanAndres', N'SRV_SANANDRES', 0),
(5, N'Cali',       N'BancoCali',      N'SRV_CALI',      0);
GO

/* ---------------------------------------------------------------------
   4. SINONIMOS HACIA LOS NODOS DE LAS SUCURSALES
   Se usan dentro de TRIGGERS y transacciones. En la simulacion (misma
   instancia) apuntan con nombre de 3 partes. En un despliegue real en
   varios servidores basta con recrearlos con 4 partes, por ejemplo:
       CREATE SYNONYM dbo.syn_Auditoria FOR SRV_MEDELLIN.BancoMedellin.dbo.Auditoria;
   sin modificar ningun trigger ni procedimiento.
   --------------------------------------------------------------------- */
-- Catalogos replicados: se valida contra la copia MAESTRA (nodo Medellín)
CREATE SYNONYM dbo.syn_TiposCuenta          FOR BancoMedellin.dbo.TiposCuenta;
CREATE SYNONYM dbo.syn_ProductosFinancieros FOR BancoMedellin.dbo.ProductosFinancieros;
-- La auditoria de las tablas principales se guarda en el nodo de la sede central
CREATE SYNONYM dbo.syn_Auditoria            FOR BancoMedellin.dbo.Auditoria;

-- Fragmentos de Sucursales y Empleados (uno por nodo)
CREATE SYNONYM dbo.syn_Sucursales_MED  FOR BancoMedellin.dbo.Sucursales;
CREATE SYNONYM dbo.syn_Sucursales_BOG  FOR BancoBogota.dbo.Sucursales;
CREATE SYNONYM dbo.syn_Sucursales_CTG  FOR BancoCartagena.dbo.Sucursales;
CREATE SYNONYM dbo.syn_Sucursales_SAI  FOR BancoSanAndres.dbo.Sucursales;
CREATE SYNONYM dbo.syn_Sucursales_CLO  FOR BancoCali.dbo.Sucursales;
CREATE SYNONYM dbo.syn_Empleados_MED   FOR BancoMedellin.dbo.Empleados;
CREATE SYNONYM dbo.syn_Empleados_BOG   FOR BancoBogota.dbo.Empleados;
CREATE SYNONYM dbo.syn_Empleados_CTG   FOR BancoCartagena.dbo.Empleados;
CREATE SYNONYM dbo.syn_Empleados_SAI   FOR BancoSanAndres.dbo.Empleados;
CREATE SYNONYM dbo.syn_Empleados_CLO   FOR BancoCali.dbo.Empleados;
GO

/* ---------------------------------------------------------------------
   5. VISTAS DE RECONSTRUCCION (UNION ALL de los fragmentos)
   Reconstruyen la tabla global de Sucursales y Empleados a partir de los
   5 nodos. Usan sinonimos (no Linked Server) para poder leerse dentro de
   triggers sin promover la transaccion a distribuida (MSDTC).
   Las versiones que viajan por los Linked Servers estan en 07_Vistas.sql
   (vw_Dist_Sucursales, vw_Dist_Empleados, vw_Dist_Auditoria).
   --------------------------------------------------------------------- */
CREATE OR ALTER VIEW dbo.vw_Sucursales
AS
SELECT 1 AS id_nodo, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM dbo.syn_Sucursales_MED
UNION ALL SELECT 2, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM dbo.syn_Sucursales_BOG
UNION ALL SELECT 3, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM dbo.syn_Sucursales_CTG
UNION ALL SELECT 4, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM dbo.syn_Sucursales_SAI
UNION ALL SELECT 5, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM dbo.syn_Sucursales_CLO;
GO

CREATE OR ALTER VIEW dbo.vw_Empleados
AS
SELECT 1 AS id_nodo, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM dbo.syn_Empleados_MED
UNION ALL SELECT 2, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM dbo.syn_Empleados_BOG
UNION ALL SELECT 3, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM dbo.syn_Empleados_CTG
UNION ALL SELECT 4, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM dbo.syn_Empleados_SAI
UNION ALL SELECT 5, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM dbo.syn_Empleados_CLO;
GO

PRINT N'>> BancoCentral (tablas, índices, nodos, sinónimos y vistas de reconstrucción) creada correctamente.';
GO
