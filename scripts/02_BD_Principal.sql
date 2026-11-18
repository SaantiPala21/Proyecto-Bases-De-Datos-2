/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 02 : BASE DE DATOS PRINCIPAL (Sede Central Medellin) -> BancoCentral
   Contiene  : Clientes, Cuentas, Transacciones, Prestamos, Pagos
               + indices + sinonimos hacia la base remota.
   Requisito : haber ejecutado 01_BD_Remota.sql
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
    id_tipo_cuenta INT           NOT NULL,   -- referencia REMOTA: BancoRemoto.dbo.TiposCuenta (validada por trigger)
    id_sucursal    INT           NOT NULL,   -- referencia REMOTA: BancoRemoto.dbo.Sucursales  (validada por trigger)
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
    id_producto      INT           NULL,     -- referencia REMOTA: BancoRemoto.dbo.ProductosFinancieros
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
   3. SINONIMOS HACIA LA BASE REMOTA
   Se usan dentro de TRIGGERS y transacciones. En la simulacion (misma
   instancia) apuntan con nombre de 3 partes. En un despliegue real en
   dos servidores basta con recrearlos con 4 partes:
       CREATE SYNONYM dbo.syn_Auditoria FOR SRV_REMOTO.BancoRemoto.dbo.Auditoria;
   sin modificar ningun trigger ni procedimiento.
   --------------------------------------------------------------------- */
CREATE SYNONYM dbo.syn_TiposCuenta          FOR BancoRemoto.dbo.TiposCuenta;
CREATE SYNONYM dbo.syn_Sucursales           FOR BancoRemoto.dbo.Sucursales;
CREATE SYNONYM dbo.syn_Empleados            FOR BancoRemoto.dbo.Empleados;
CREATE SYNONYM dbo.syn_ProductosFinancieros FOR BancoRemoto.dbo.ProductosFinancieros;
CREATE SYNONYM dbo.syn_Auditoria            FOR BancoRemoto.dbo.Auditoria;
GO

PRINT N'>> BancoCentral (tablas, índices y sinónimos) creada correctamente.';
GO
