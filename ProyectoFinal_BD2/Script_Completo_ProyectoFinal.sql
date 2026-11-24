/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3 - SCRIPT COMPLETO
   Sistema Distribuido para una Entidad Financiera (SQL Server)
   Base principal BancoCentral + 5 bases remotas (una por sucursal)
   Creacion + datos + logica + consultas + pruebas (scripts 01 a 10)
   ===================================================================== */

-- #####################################################################
-- ARCHIVO: 01_BD_Remotas_Sucursales.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   Sistema Distribuido para una Entidad Financiera
   ---------------------------------------------------------------------
   SCRIPT 01 : BASES DE DATOS REMOTAS (UNA POR SUCURSAL)
     Nodo 1  BancoMedellin   (Medellín - sede central)  SRV_MEDELLIN
     Nodo 2  BancoBogota     (Bogotá)                   SRV_BOGOTA
     Nodo 3  BancoCartagena  (Cartagena)                SRV_CARTAGENA
     Nodo 4  BancoSanAndres  (San Andrés)               SRV_SANANDRES
     Nodo 5  BancoCali       (Cali)                     SRV_CALI
   Cada nodo contiene: Tipos de cuenta, Sucursales, Empleados,
   Productos financieros e Historial/Auditoria + triggers + CRUD.

   Distribucion dentro de los nodos:
     - TiposCuenta y ProductosFinancieros : REPLICADOS (mismos datos e ids
       en los 5 nodos; la copia maestra es la de Medellín y la sede central
       propaga los cambios con sp_Dist_* por los Linked Servers).
     - Sucursales y Empleados : FRAGMENTACION HORIZONTAL por ciudad
       (cada nodo guarda solo las sucursales y empleados de su ciudad).
     - Auditoria : historial local de cada nodo.
   Ejecutar  : en SSMS, conectado a la instancia, con permisos sysadmin.
   ===================================================================== */
USE master;
GO

/* Limpieza de la version anterior del proyecto (una sola base remota) */
IF EXISTS (SELECT 1 FROM sys.servers WHERE name = N'SRV_REMOTO')
    EXEC master.dbo.sp_dropserver @server = N'SRV_REMOTO', @droplogins = 'droplogins';
IF DB_ID(N'BancoRemoto') IS NOT NULL
BEGIN
    ALTER DATABASE BancoRemoto SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoRemoto;
END
GO
/* #####################################################################
   NODO 1 : BancoMedellin   (Sucursal Medellín)  -> Linked Server SRV_MEDELLIN
   ##################################################################### */
USE master;
GO
IF DB_ID(N'BancoMedellin') IS NOT NULL
BEGIN
    ALTER DATABASE BancoMedellin SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoMedellin;
END
GO
CREATE DATABASE BancoMedellin;
GO
USE BancoMedellin;
GO

/* ---------------------------------------------------------------------
   1.1 TABLAS
   --------------------------------------------------------------------- */
-- Catalogo REPLICADO en todos los nodos (la copia maestra es la de Medellin).
-- El id es explicito (sin IDENTITY) para que sea el mismo en todas las sedes.
CREATE TABLE dbo.TiposCuenta
(
    id_tipo_cuenta INT NOT NULL CONSTRAINT PK_TiposCuenta PRIMARY KEY,
    nombre         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_TiposCuenta_nombre UNIQUE,
    descripcion    NVARCHAR(200) NULL
);
GO

-- Fragmento HORIZONTAL: este nodo solo guarda las sucursales de Medellín.
-- IDENTITY(101,1): las sucursales nuevas de este nodo reciben ids 101, 102, ...
-- (la sucursal principal de la ciudad conserva el id 1), asi el id es unico en todo el sistema.
CREATE TABLE dbo.Sucursales
(
    id_sucursal     INT IDENTITY(101,1) NOT NULL CONSTRAINT PK_Sucursales PRIMARY KEY,
    nombre          NVARCHAR(80)  NOT NULL CONSTRAINT UQ_Sucursales_nombre UNIQUE,
    ciudad          NVARCHAR(50)  NOT NULL CONSTRAINT DF_Sucursales_ciudad DEFAULT (N'Medellín'),
    direccion       NVARCHAR(150) NULL,
    es_sede_central BIT NOT NULL CONSTRAINT DF_Sucursales_central DEFAULT (0),
    CONSTRAINT CK_Sucursales_ciudad CHECK (ciudad = N'Medellín')
);
GO
-- Este es el nodo de la SEDE CENTRAL: solo puede existir una sede central
CREATE UNIQUE INDEX UX_Sucursales_SedeCentral ON dbo.Sucursales(es_sede_central) WHERE es_sede_central = 1;
GO

-- Fragmento HORIZONTAL: empleados de las sucursales de Medellín.
CREATE TABLE dbo.Empleados
(
    id_empleado INT IDENTITY(1001,1) NOT NULL CONSTRAINT PK_Empleados PRIMARY KEY,
    nombre      NVARCHAR(100) NOT NULL,
    documento   VARCHAR(20)   NOT NULL CONSTRAINT UQ_Empleados_documento UNIQUE,
    cargo       NVARCHAR(50)  NOT NULL,
    id_sucursal INT NOT NULL CONSTRAINT FK_Empleados_Sucursales REFERENCES dbo.Sucursales(id_sucursal),
    activo      BIT NOT NULL CONSTRAINT DF_Empleados_activo DEFAULT (1)
);
GO
CREATE INDEX IX_Empleados_sucursal ON dbo.Empleados(id_sucursal);
GO

-- Catalogo REPLICADO (copia maestra en Medellin).
CREATE TABLE dbo.ProductosFinancieros
(
    id_producto  INT NOT NULL CONSTRAINT PK_ProductosFinancieros PRIMARY KEY,
    nombre       NVARCHAR(80) NOT NULL CONSTRAINT UQ_Productos_nombre UNIQUE,
    categoria    VARCHAR(10)  NOT NULL CONSTRAINT CK_Productos_categoria CHECK (categoria IN ('AHORRO','CREDITO','INVERSION','SEGURO')),
    tasa_interes DECIMAL(5,2) NOT NULL CONSTRAINT CK_Productos_tasa CHECK (tasa_interes BETWEEN 0 AND 100),
    descripcion  NVARCHAR(200) NULL,
    activo       BIT NOT NULL CONSTRAINT DF_Productos_activo DEFAULT (1)
);
GO

-- Historial / auditoria propio del nodo.
CREATE TABLE dbo.Auditoria
(
    id_auditoria     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Auditoria PRIMARY KEY,
    base_datos       SYSNAME      NOT NULL,
    tabla            SYSNAME      NOT NULL,
    operacion        VARCHAR(10)  NOT NULL CONSTRAINT CK_Auditoria_operacion CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    id_registro      INT          NULL,
    datos_anteriores NVARCHAR(MAX) NULL,   -- JSON con la fila antes del cambio
    datos_nuevos     NVARCHAR(MAX) NULL,   -- JSON con la fila despues del cambio
    usuario          SYSNAME      NOT NULL CONSTRAINT DF_Auditoria_usuario DEFAULT (SUSER_SNAME()),
    fecha            DATETIME2(0) NOT NULL CONSTRAINT DF_Auditoria_fecha   DEFAULT (SYSDATETIME())
);
GO
CREATE INDEX IX_Auditoria_tabla_fecha ON dbo.Auditoria(tabla, fecha);
GO

/* Sinonimos hacia la base principal: permiten que los triggers de este
   nodo verifiquen si un registro esta siendo usado en BancoCentral. */
CREATE SYNONYM dbo.syn_CuentasCentral   FOR BancoCentral.dbo.Cuentas;
CREATE SYNONYM dbo.syn_PrestamosCentral FOR BancoCentral.dbo.Prestamos;
GO

/* ---------------------------------------------------------------------
   1.2 TRIGGERS (minimo uno por tabla)
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_Auditoria ON dbo.TiposCuenta
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'TiposCuenta',
           CASE WHEN i.id_tipo_cuenta IS NOT NULL AND d.id_tipo_cuenta IS NOT NULL THEN 'UPDATE'
                WHEN i.id_tipo_cuenta IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_tipo_cuenta, d.id_tipo_cuenta),
           (SELECT x.* FROM deleted  x WHERE x.id_tipo_cuenta = d.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_tipo_cuenta = i.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_tipo_cuenta = i.id_tipo_cuenta;
END;
GO

-- Integridad distribuida: no borrar un tipo de cuenta usado en BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_EvitarEliminacion ON dbo.TiposCuenta
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_tipo_cuenta = d.id_tipo_cuenta)
        THROW 51001, N'No se puede eliminar el tipo de cuenta: existen cuentas en BancoCentral que lo utilizan.', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Auditoria ON dbo.Sucursales
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Sucursales',
           CASE WHEN i.id_sucursal IS NOT NULL AND d.id_sucursal IS NOT NULL THEN 'UPDATE'
                WHEN i.id_sucursal IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_sucursal, d.id_sucursal),
           (SELECT x.* FROM deleted  x WHERE x.id_sucursal = d.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_sucursal = i.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_sucursal = i.id_sucursal;
END;
GO

-- Control de Sucursales: no borrar la sede central, ni sucursales con empleados o con cuentas
CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Control ON dbo.Sucursales
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted WHERE es_sede_central = 1)
        THROW 51002, N'No se puede eliminar la sede central (Medellín): gestiona todas las sedes.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.Empleados e ON e.id_sucursal = d.id_sucursal)
        THROW 51006, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_sucursal = d.id_sucursal)
        THROW 51003, N'No se puede eliminar la sucursal: tiene cuentas registradas en BancoCentral.', 1;

    DELETE s FROM dbo.Sucursales s JOIN deleted d ON d.id_sucursal = s.id_sucursal;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Empleados_Auditoria ON dbo.Empleados
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Empleados',
           CASE WHEN i.id_empleado IS NOT NULL AND d.id_empleado IS NOT NULL THEN 'UPDATE'
                WHEN i.id_empleado IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_empleado, d.id_empleado),
           (SELECT x.* FROM deleted  x WHERE x.id_empleado = d.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_empleado = i.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_empleado = i.id_empleado;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Productos_Auditoria ON dbo.ProductosFinancieros
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'ProductosFinancieros',
           CASE WHEN i.id_producto IS NOT NULL AND d.id_producto IS NOT NULL THEN 'UPDATE'
                WHEN i.id_producto IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_producto, d.id_producto),
           (SELECT x.* FROM deleted  x WHERE x.id_producto = d.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_producto = i.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_producto = i.id_producto;
END;
GO

-- Integridad distribuida: no borrar un producto usado por prestamos de BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_Productos_EvitarEliminacion ON dbo.ProductosFinancieros
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_PrestamosCentral p ON p.id_producto = d.id_producto)
        THROW 51004, N'No se puede eliminar el producto: hay préstamos en BancoCentral asociados. Desactívelo (activo = 0).', 1;
END;
GO

-- La auditoria es inmutable
CREATE OR ALTER TRIGGER dbo.tr_Auditoria_Inmutable ON dbo.Auditoria
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51005, N'El historial de auditoría es de solo lectura: no se permite UPDATE ni DELETE.', 1;
END;
GO

/* ---------------------------------------------------------------------
   1.3 PROCEDIMIENTOS CRUD DEL NODO
   --------------------------------------------------------------------- */
/* ========== TIPOS DE CUENTA (catalogo replicado) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Insertar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50),
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @id_tipo_cuenta IS NULL OR @id_tipo_cuenta <= 0
            THROW 51100, N'El id del tipo de cuenta es obligatorio (catálogo replicado: el id lo asigna la sede central).', 1;
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51101, N'El nombre del tipo de cuenta es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre OR id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese id o nombre.', 1;

        INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES (@id_tipo_cuenta, @nombre, @descripcion);
        SELECT N'Tipo de cuenta registrado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Consultar
    @id_tipo_cuenta INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_tipo_cuenta, nombre, descripcion, DB_NAME() AS nodo
        FROM dbo.TiposCuenta
        WHERE @id_tipo_cuenta IS NULL OR id_tipo_cuenta = @id_tipo_cuenta
        ORDER BY id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Actualizar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50)  = NULL,
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;
        IF @nombre IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre AND id_tipo_cuenta <> @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese nombre.', 1;

        UPDATE dbo.TiposCuenta
           SET nombre      = COALESCE(@nombre, nombre),
               descripcion = COALESCE(@descripcion, descripcion)
         WHERE id_tipo_cuenta = @id_tipo_cuenta;
        SELECT N'Tipo de cuenta actualizado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Eliminar
    @id_tipo_cuenta INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;

        DELETE FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta;  -- el trigger valida uso en BancoCentral
        SELECT N'Tipo de cuenta eliminado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== SUCURSALES (solo las de Medellín) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Insertar
    @nombre      NVARCHAR(80),
    @ciudad      NVARCHAR(50)  = N'Medellín',
    @direccion   NVARCHAR(150) = NULL,
    @id_sucursal INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51201, N'El nombre de la sucursal es obligatorio.', 1;
        IF ISNULL(@ciudad, N'') <> N'Medellín'
            THROW 51202, N'Este nodo (BancoMedellin) solo administra sucursales de Medellín. Use el Linked Server de la ciudad correspondiente.', 1;

        INSERT INTO dbo.Sucursales (nombre, ciudad, direccion, es_sede_central)
        VALUES (@nombre, @ciudad, @direccion, 0);
        SET @id_sucursal = SCOPE_IDENTITY();
        SELECT N'Sucursal registrada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Consultar
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre, s.ciudad, s.direccion,
               CASE WHEN s.es_sede_central = 1 THEN N'SEDE CENTRAL' ELSE N'Sucursal' END AS tipo_sede,
               (SELECT COUNT(*) FROM dbo.Empleados e WHERE e.id_sucursal = s.id_sucursal AND e.activo = 1) AS empleados_activos,
               DB_NAME() AS nodo
        FROM dbo.Sucursales s
        WHERE @id_sucursal IS NULL OR s.id_sucursal = @id_sucursal
        ORDER BY s.id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Actualizar
    @id_sucursal INT,
    @nombre      NVARCHAR(80)  = NULL,
    @direccion   NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;

        UPDATE dbo.Sucursales
           SET nombre    = COALESCE(@nombre, nombre),
               direccion = COALESCE(@direccion, direccion)
         WHERE id_sucursal = @id_sucursal;
        SELECT N'Sucursal actualizada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Eliminar
    @id_sucursal INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_sucursal = @id_sucursal)
            THROW 51204, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

        DELETE FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal;  -- el trigger valida sede central y cuentas
        SELECT N'Sucursal eliminada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== EMPLEADOS (de las sucursales de Medellín) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Insertar
    @nombre      NVARCHAR(100),
    @documento   VARCHAR(20),
    @cargo       NVARCHAR(50),
    @id_sucursal INT,
    @id_empleado INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51301, N'El nombre del empleado es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE documento = @documento)
            THROW 51302, N'Ya existe un empleado con ese documento en este nodo.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Medellín).', 1;

        INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal)
        VALUES (@nombre, @documento, @cargo, @id_sucursal);
        SET @id_empleado = SCOPE_IDENTITY();
        SELECT N'Empleado registrado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Consultar
    @id_empleado INT = NULL,
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT e.id_empleado, e.nombre, e.documento, e.cargo,
               s.nombre AS sucursal, s.ciudad,
               CASE WHEN e.activo = 1 THEN 'ACTIVO' ELSE 'INACTIVO' END AS estado,
               DB_NAME() AS nodo
        FROM dbo.Empleados e
        JOIN dbo.Sucursales s ON s.id_sucursal = e.id_sucursal
        WHERE (@id_empleado IS NULL OR e.id_empleado = @id_empleado)
          AND (@id_sucursal IS NULL OR e.id_sucursal = @id_sucursal)
        ORDER BY s.id_sucursal, e.nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Actualizar
    @id_empleado INT,
    @nombre      NVARCHAR(100) = NULL,
    @cargo       NVARCHAR(50)  = NULL,
    @id_sucursal INT = NULL,
    @activo      BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;
        IF @id_sucursal IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Medellín).', 1;

        UPDATE dbo.Empleados
           SET nombre      = COALESCE(@nombre, nombre),
               cargo       = COALESCE(@cargo, cargo),
               id_sucursal = COALESCE(@id_sucursal, id_sucursal),
               activo      = COALESCE(@activo, activo)
         WHERE id_empleado = @id_empleado;
        SELECT N'Empleado actualizado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Eliminar
    @id_empleado INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;

        DELETE FROM dbo.Empleados WHERE id_empleado = @id_empleado;
        SELECT N'Empleado eliminado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Consulta de productos financieros (catalogo replicado) */
CREATE OR ALTER PROCEDURE dbo.sp_Producto_Consultar
    @categoria VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_producto, nombre, categoria, tasa_interes, descripcion, activo, DB_NAME() AS nodo
        FROM dbo.ProductosFinancieros
        WHERE @categoria IS NULL OR categoria = @categoria
        ORDER BY categoria, nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   1.4 DATOS INICIALES DEL NODO
   --------------------------------------------------------------------- */
-- Catalogos replicados (mismos ids en las 5 sedes)
INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES
(1, N'Ahorros',           N'Cuenta de ahorros tradicional con rendimiento mensual'),
(2, N'Corriente',         N'Cuenta corriente para manejo de chequera y pagos empresariales'),
(3, N'Nómina',            N'Cuenta de ahorros para recibir el pago de salario'),
(4, N'Ahorro programado', N'Cuenta con meta de ahorro y aportes periódicos');
GO

INSERT INTO dbo.ProductosFinancieros (id_producto, nombre, categoria, tasa_interes, descripcion) VALUES
(1, N'Crédito de libre inversión', 'CREDITO',   18.00, N'Préstamo de consumo sin destinación específica'),
(2, N'Crédito hipotecario',        'CREDITO',   11.00, N'Financiación de vivienda a largo plazo'),
(3, N'Crédito vehicular',          'CREDITO',   15.00, N'Financiación para compra de vehículo'),
(4, N'Crédito empresarial',        'CREDITO',   14.00, N'Capital de trabajo para personas jurídicas'),
(5, N'Cuenta de ahorros',          'AHORRO',     1.50, N'Rendimiento efectivo anual de la cuenta de ahorros'),
(6, N'CDT 180 días',               'INVERSION',  9.50, N'Certificado de depósito a término fijo'),
(7, N'Seguro de vida deudor',      'SEGURO',     0.00, N'Seguro obligatorio asociado a créditos');
GO

-- Sucursal principal de la ciudad (id fijo = 1)
SET IDENTITY_INSERT dbo.Sucursales ON;
INSERT INTO dbo.Sucursales (id_sucursal, nombre, ciudad, direccion, es_sede_central)
VALUES (1, N'Sede Central Medellín', N'Medellín', N'Calle 50 # 52-20, La Candelaria', 1);
SET IDENTITY_INSERT dbo.Sucursales OFF;
GO

INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal) VALUES
(N'Laura Gómez Arango',      '1017200001', N'Gerente General',     1),
(N'Andrés Felipe Zapata',    '1017200002', N'Analista de Crédito', 1),
(N'Diana Marcela Ríos',      '1017200003', N'Cajero',              1),
(N'Esteban Restrepo Mejía',  '1017200012', N'Auditor Interno',     1);
GO

PRINT N'>> Nodo BancoMedellin (Medellín) creado correctamente.';
GO

/* #####################################################################
   NODO 2 : BancoBogota   (Sucursal Bogotá)  -> Linked Server SRV_BOGOTA
   ##################################################################### */
USE master;
GO
IF DB_ID(N'BancoBogota') IS NOT NULL
BEGIN
    ALTER DATABASE BancoBogota SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoBogota;
END
GO
CREATE DATABASE BancoBogota;
GO
USE BancoBogota;
GO

/* ---------------------------------------------------------------------
   2.1 TABLAS
   --------------------------------------------------------------------- */
-- Catalogo REPLICADO en todos los nodos (la copia maestra es la de Medellin).
-- El id es explicito (sin IDENTITY) para que sea el mismo en todas las sedes.
CREATE TABLE dbo.TiposCuenta
(
    id_tipo_cuenta INT NOT NULL CONSTRAINT PK_TiposCuenta PRIMARY KEY,
    nombre         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_TiposCuenta_nombre UNIQUE,
    descripcion    NVARCHAR(200) NULL
);
GO

-- Fragmento HORIZONTAL: este nodo solo guarda las sucursales de Bogotá.
-- IDENTITY(201,1): las sucursales nuevas de este nodo reciben ids 201, 202, ...
-- (la sucursal principal de la ciudad conserva el id 2), asi el id es unico en todo el sistema.
CREATE TABLE dbo.Sucursales
(
    id_sucursal     INT IDENTITY(201,1) NOT NULL CONSTRAINT PK_Sucursales PRIMARY KEY,
    nombre          NVARCHAR(80)  NOT NULL CONSTRAINT UQ_Sucursales_nombre UNIQUE,
    ciudad          NVARCHAR(50)  NOT NULL CONSTRAINT DF_Sucursales_ciudad DEFAULT (N'Bogotá'),
    direccion       NVARCHAR(150) NULL,
    es_sede_central BIT NOT NULL CONSTRAINT DF_Sucursales_central DEFAULT (0),
    CONSTRAINT CK_Sucursales_ciudad CHECK (ciudad = N'Bogotá')
);
GO
-- La sede central esta en Medellín: en este nodo ninguna sucursal puede serlo
ALTER TABLE dbo.Sucursales ADD CONSTRAINT CK_Sucursales_NoCentral CHECK (es_sede_central = 0);
GO

-- Fragmento HORIZONTAL: empleados de las sucursales de Bogotá.
CREATE TABLE dbo.Empleados
(
    id_empleado INT IDENTITY(2001,1) NOT NULL CONSTRAINT PK_Empleados PRIMARY KEY,
    nombre      NVARCHAR(100) NOT NULL,
    documento   VARCHAR(20)   NOT NULL CONSTRAINT UQ_Empleados_documento UNIQUE,
    cargo       NVARCHAR(50)  NOT NULL,
    id_sucursal INT NOT NULL CONSTRAINT FK_Empleados_Sucursales REFERENCES dbo.Sucursales(id_sucursal),
    activo      BIT NOT NULL CONSTRAINT DF_Empleados_activo DEFAULT (1)
);
GO
CREATE INDEX IX_Empleados_sucursal ON dbo.Empleados(id_sucursal);
GO

-- Catalogo REPLICADO (copia maestra en Medellin).
CREATE TABLE dbo.ProductosFinancieros
(
    id_producto  INT NOT NULL CONSTRAINT PK_ProductosFinancieros PRIMARY KEY,
    nombre       NVARCHAR(80) NOT NULL CONSTRAINT UQ_Productos_nombre UNIQUE,
    categoria    VARCHAR(10)  NOT NULL CONSTRAINT CK_Productos_categoria CHECK (categoria IN ('AHORRO','CREDITO','INVERSION','SEGURO')),
    tasa_interes DECIMAL(5,2) NOT NULL CONSTRAINT CK_Productos_tasa CHECK (tasa_interes BETWEEN 0 AND 100),
    descripcion  NVARCHAR(200) NULL,
    activo       BIT NOT NULL CONSTRAINT DF_Productos_activo DEFAULT (1)
);
GO

-- Historial / auditoria propio del nodo.
CREATE TABLE dbo.Auditoria
(
    id_auditoria     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Auditoria PRIMARY KEY,
    base_datos       SYSNAME      NOT NULL,
    tabla            SYSNAME      NOT NULL,
    operacion        VARCHAR(10)  NOT NULL CONSTRAINT CK_Auditoria_operacion CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    id_registro      INT          NULL,
    datos_anteriores NVARCHAR(MAX) NULL,   -- JSON con la fila antes del cambio
    datos_nuevos     NVARCHAR(MAX) NULL,   -- JSON con la fila despues del cambio
    usuario          SYSNAME      NOT NULL CONSTRAINT DF_Auditoria_usuario DEFAULT (SUSER_SNAME()),
    fecha            DATETIME2(0) NOT NULL CONSTRAINT DF_Auditoria_fecha   DEFAULT (SYSDATETIME())
);
GO
CREATE INDEX IX_Auditoria_tabla_fecha ON dbo.Auditoria(tabla, fecha);
GO

/* Sinonimos hacia la base principal: permiten que los triggers de este
   nodo verifiquen si un registro esta siendo usado en BancoCentral. */
CREATE SYNONYM dbo.syn_CuentasCentral   FOR BancoCentral.dbo.Cuentas;
CREATE SYNONYM dbo.syn_PrestamosCentral FOR BancoCentral.dbo.Prestamos;
GO

/* ---------------------------------------------------------------------
   2.2 TRIGGERS (minimo uno por tabla)
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_Auditoria ON dbo.TiposCuenta
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'TiposCuenta',
           CASE WHEN i.id_tipo_cuenta IS NOT NULL AND d.id_tipo_cuenta IS NOT NULL THEN 'UPDATE'
                WHEN i.id_tipo_cuenta IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_tipo_cuenta, d.id_tipo_cuenta),
           (SELECT x.* FROM deleted  x WHERE x.id_tipo_cuenta = d.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_tipo_cuenta = i.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_tipo_cuenta = i.id_tipo_cuenta;
END;
GO

-- Integridad distribuida: no borrar un tipo de cuenta usado en BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_EvitarEliminacion ON dbo.TiposCuenta
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_tipo_cuenta = d.id_tipo_cuenta)
        THROW 51001, N'No se puede eliminar el tipo de cuenta: existen cuentas en BancoCentral que lo utilizan.', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Auditoria ON dbo.Sucursales
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Sucursales',
           CASE WHEN i.id_sucursal IS NOT NULL AND d.id_sucursal IS NOT NULL THEN 'UPDATE'
                WHEN i.id_sucursal IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_sucursal, d.id_sucursal),
           (SELECT x.* FROM deleted  x WHERE x.id_sucursal = d.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_sucursal = i.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_sucursal = i.id_sucursal;
END;
GO

-- Control de Sucursales: no borrar la sede central, ni sucursales con empleados o con cuentas
CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Control ON dbo.Sucursales
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted WHERE es_sede_central = 1)
        THROW 51002, N'No se puede eliminar la sede central (Medellín): gestiona todas las sedes.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.Empleados e ON e.id_sucursal = d.id_sucursal)
        THROW 51006, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_sucursal = d.id_sucursal)
        THROW 51003, N'No se puede eliminar la sucursal: tiene cuentas registradas en BancoCentral.', 1;

    DELETE s FROM dbo.Sucursales s JOIN deleted d ON d.id_sucursal = s.id_sucursal;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Empleados_Auditoria ON dbo.Empleados
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Empleados',
           CASE WHEN i.id_empleado IS NOT NULL AND d.id_empleado IS NOT NULL THEN 'UPDATE'
                WHEN i.id_empleado IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_empleado, d.id_empleado),
           (SELECT x.* FROM deleted  x WHERE x.id_empleado = d.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_empleado = i.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_empleado = i.id_empleado;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Productos_Auditoria ON dbo.ProductosFinancieros
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'ProductosFinancieros',
           CASE WHEN i.id_producto IS NOT NULL AND d.id_producto IS NOT NULL THEN 'UPDATE'
                WHEN i.id_producto IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_producto, d.id_producto),
           (SELECT x.* FROM deleted  x WHERE x.id_producto = d.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_producto = i.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_producto = i.id_producto;
END;
GO

-- Integridad distribuida: no borrar un producto usado por prestamos de BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_Productos_EvitarEliminacion ON dbo.ProductosFinancieros
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_PrestamosCentral p ON p.id_producto = d.id_producto)
        THROW 51004, N'No se puede eliminar el producto: hay préstamos en BancoCentral asociados. Desactívelo (activo = 0).', 1;
END;
GO

-- La auditoria es inmutable
CREATE OR ALTER TRIGGER dbo.tr_Auditoria_Inmutable ON dbo.Auditoria
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51005, N'El historial de auditoría es de solo lectura: no se permite UPDATE ni DELETE.', 1;
END;
GO

/* ---------------------------------------------------------------------
   2.3 PROCEDIMIENTOS CRUD DEL NODO
   --------------------------------------------------------------------- */
/* ========== TIPOS DE CUENTA (catalogo replicado) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Insertar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50),
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @id_tipo_cuenta IS NULL OR @id_tipo_cuenta <= 0
            THROW 51100, N'El id del tipo de cuenta es obligatorio (catálogo replicado: el id lo asigna la sede central).', 1;
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51101, N'El nombre del tipo de cuenta es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre OR id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese id o nombre.', 1;

        INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES (@id_tipo_cuenta, @nombre, @descripcion);
        SELECT N'Tipo de cuenta registrado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Consultar
    @id_tipo_cuenta INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_tipo_cuenta, nombre, descripcion, DB_NAME() AS nodo
        FROM dbo.TiposCuenta
        WHERE @id_tipo_cuenta IS NULL OR id_tipo_cuenta = @id_tipo_cuenta
        ORDER BY id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Actualizar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50)  = NULL,
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;
        IF @nombre IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre AND id_tipo_cuenta <> @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese nombre.', 1;

        UPDATE dbo.TiposCuenta
           SET nombre      = COALESCE(@nombre, nombre),
               descripcion = COALESCE(@descripcion, descripcion)
         WHERE id_tipo_cuenta = @id_tipo_cuenta;
        SELECT N'Tipo de cuenta actualizado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Eliminar
    @id_tipo_cuenta INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;

        DELETE FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta;  -- el trigger valida uso en BancoCentral
        SELECT N'Tipo de cuenta eliminado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== SUCURSALES (solo las de Bogotá) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Insertar
    @nombre      NVARCHAR(80),
    @ciudad      NVARCHAR(50)  = N'Bogotá',
    @direccion   NVARCHAR(150) = NULL,
    @id_sucursal INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51201, N'El nombre de la sucursal es obligatorio.', 1;
        IF ISNULL(@ciudad, N'') <> N'Bogotá'
            THROW 51202, N'Este nodo (BancoBogota) solo administra sucursales de Bogotá. Use el Linked Server de la ciudad correspondiente.', 1;

        INSERT INTO dbo.Sucursales (nombre, ciudad, direccion, es_sede_central)
        VALUES (@nombre, @ciudad, @direccion, 0);
        SET @id_sucursal = SCOPE_IDENTITY();
        SELECT N'Sucursal registrada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Consultar
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre, s.ciudad, s.direccion,
               CASE WHEN s.es_sede_central = 1 THEN N'SEDE CENTRAL' ELSE N'Sucursal' END AS tipo_sede,
               (SELECT COUNT(*) FROM dbo.Empleados e WHERE e.id_sucursal = s.id_sucursal AND e.activo = 1) AS empleados_activos,
               DB_NAME() AS nodo
        FROM dbo.Sucursales s
        WHERE @id_sucursal IS NULL OR s.id_sucursal = @id_sucursal
        ORDER BY s.id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Actualizar
    @id_sucursal INT,
    @nombre      NVARCHAR(80)  = NULL,
    @direccion   NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;

        UPDATE dbo.Sucursales
           SET nombre    = COALESCE(@nombre, nombre),
               direccion = COALESCE(@direccion, direccion)
         WHERE id_sucursal = @id_sucursal;
        SELECT N'Sucursal actualizada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Eliminar
    @id_sucursal INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_sucursal = @id_sucursal)
            THROW 51204, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

        DELETE FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal;  -- el trigger valida sede central y cuentas
        SELECT N'Sucursal eliminada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== EMPLEADOS (de las sucursales de Bogotá) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Insertar
    @nombre      NVARCHAR(100),
    @documento   VARCHAR(20),
    @cargo       NVARCHAR(50),
    @id_sucursal INT,
    @id_empleado INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51301, N'El nombre del empleado es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE documento = @documento)
            THROW 51302, N'Ya existe un empleado con ese documento en este nodo.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Bogotá).', 1;

        INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal)
        VALUES (@nombre, @documento, @cargo, @id_sucursal);
        SET @id_empleado = SCOPE_IDENTITY();
        SELECT N'Empleado registrado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Consultar
    @id_empleado INT = NULL,
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT e.id_empleado, e.nombre, e.documento, e.cargo,
               s.nombre AS sucursal, s.ciudad,
               CASE WHEN e.activo = 1 THEN 'ACTIVO' ELSE 'INACTIVO' END AS estado,
               DB_NAME() AS nodo
        FROM dbo.Empleados e
        JOIN dbo.Sucursales s ON s.id_sucursal = e.id_sucursal
        WHERE (@id_empleado IS NULL OR e.id_empleado = @id_empleado)
          AND (@id_sucursal IS NULL OR e.id_sucursal = @id_sucursal)
        ORDER BY s.id_sucursal, e.nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Actualizar
    @id_empleado INT,
    @nombre      NVARCHAR(100) = NULL,
    @cargo       NVARCHAR(50)  = NULL,
    @id_sucursal INT = NULL,
    @activo      BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;
        IF @id_sucursal IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Bogotá).', 1;

        UPDATE dbo.Empleados
           SET nombre      = COALESCE(@nombre, nombre),
               cargo       = COALESCE(@cargo, cargo),
               id_sucursal = COALESCE(@id_sucursal, id_sucursal),
               activo      = COALESCE(@activo, activo)
         WHERE id_empleado = @id_empleado;
        SELECT N'Empleado actualizado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Eliminar
    @id_empleado INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;

        DELETE FROM dbo.Empleados WHERE id_empleado = @id_empleado;
        SELECT N'Empleado eliminado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Consulta de productos financieros (catalogo replicado) */
CREATE OR ALTER PROCEDURE dbo.sp_Producto_Consultar
    @categoria VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_producto, nombre, categoria, tasa_interes, descripcion, activo, DB_NAME() AS nodo
        FROM dbo.ProductosFinancieros
        WHERE @categoria IS NULL OR categoria = @categoria
        ORDER BY categoria, nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   2.4 DATOS INICIALES DEL NODO
   --------------------------------------------------------------------- */
-- Catalogos replicados (mismos ids en las 5 sedes)
INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES
(1, N'Ahorros',           N'Cuenta de ahorros tradicional con rendimiento mensual'),
(2, N'Corriente',         N'Cuenta corriente para manejo de chequera y pagos empresariales'),
(3, N'Nómina',            N'Cuenta de ahorros para recibir el pago de salario'),
(4, N'Ahorro programado', N'Cuenta con meta de ahorro y aportes periódicos');
GO

INSERT INTO dbo.ProductosFinancieros (id_producto, nombre, categoria, tasa_interes, descripcion) VALUES
(1, N'Crédito de libre inversión', 'CREDITO',   18.00, N'Préstamo de consumo sin destinación específica'),
(2, N'Crédito hipotecario',        'CREDITO',   11.00, N'Financiación de vivienda a largo plazo'),
(3, N'Crédito vehicular',          'CREDITO',   15.00, N'Financiación para compra de vehículo'),
(4, N'Crédito empresarial',        'CREDITO',   14.00, N'Capital de trabajo para personas jurídicas'),
(5, N'Cuenta de ahorros',          'AHORRO',     1.50, N'Rendimiento efectivo anual de la cuenta de ahorros'),
(6, N'CDT 180 días',               'INVERSION',  9.50, N'Certificado de depósito a término fijo'),
(7, N'Seguro de vida deudor',      'SEGURO',     0.00, N'Seguro obligatorio asociado a créditos');
GO

-- Sucursal principal de la ciudad (id fijo = 2)
SET IDENTITY_INSERT dbo.Sucursales ON;
INSERT INTO dbo.Sucursales (id_sucursal, nombre, ciudad, direccion, es_sede_central)
VALUES (2, N'Sucursal Bogotá', N'Bogotá', N'Carrera 7 # 72-41, Chapinero', 0);
SET IDENTITY_INSERT dbo.Sucursales OFF;
GO

INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal) VALUES
(N'Santiago Rojas Pardo',    '1018200004', N'Gerente de Sucursal', 2),
(N'Natalia Vargas León',     '1018200005', N'Asesor Comercial',    2);
GO

PRINT N'>> Nodo BancoBogota (Bogotá) creado correctamente.';
GO

/* #####################################################################
   NODO 3 : BancoCartagena   (Sucursal Cartagena)  -> Linked Server SRV_CARTAGENA
   ##################################################################### */
USE master;
GO
IF DB_ID(N'BancoCartagena') IS NOT NULL
BEGIN
    ALTER DATABASE BancoCartagena SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoCartagena;
END
GO
CREATE DATABASE BancoCartagena;
GO
USE BancoCartagena;
GO

/* ---------------------------------------------------------------------
   3.1 TABLAS
   --------------------------------------------------------------------- */
-- Catalogo REPLICADO en todos los nodos (la copia maestra es la de Medellin).
-- El id es explicito (sin IDENTITY) para que sea el mismo en todas las sedes.
CREATE TABLE dbo.TiposCuenta
(
    id_tipo_cuenta INT NOT NULL CONSTRAINT PK_TiposCuenta PRIMARY KEY,
    nombre         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_TiposCuenta_nombre UNIQUE,
    descripcion    NVARCHAR(200) NULL
);
GO

-- Fragmento HORIZONTAL: este nodo solo guarda las sucursales de Cartagena.
-- IDENTITY(301,1): las sucursales nuevas de este nodo reciben ids 301, 302, ...
-- (la sucursal principal de la ciudad conserva el id 3), asi el id es unico en todo el sistema.
CREATE TABLE dbo.Sucursales
(
    id_sucursal     INT IDENTITY(301,1) NOT NULL CONSTRAINT PK_Sucursales PRIMARY KEY,
    nombre          NVARCHAR(80)  NOT NULL CONSTRAINT UQ_Sucursales_nombre UNIQUE,
    ciudad          NVARCHAR(50)  NOT NULL CONSTRAINT DF_Sucursales_ciudad DEFAULT (N'Cartagena'),
    direccion       NVARCHAR(150) NULL,
    es_sede_central BIT NOT NULL CONSTRAINT DF_Sucursales_central DEFAULT (0),
    CONSTRAINT CK_Sucursales_ciudad CHECK (ciudad = N'Cartagena')
);
GO
-- La sede central esta en Medellín: en este nodo ninguna sucursal puede serlo
ALTER TABLE dbo.Sucursales ADD CONSTRAINT CK_Sucursales_NoCentral CHECK (es_sede_central = 0);
GO

-- Fragmento HORIZONTAL: empleados de las sucursales de Cartagena.
CREATE TABLE dbo.Empleados
(
    id_empleado INT IDENTITY(3001,1) NOT NULL CONSTRAINT PK_Empleados PRIMARY KEY,
    nombre      NVARCHAR(100) NOT NULL,
    documento   VARCHAR(20)   NOT NULL CONSTRAINT UQ_Empleados_documento UNIQUE,
    cargo       NVARCHAR(50)  NOT NULL,
    id_sucursal INT NOT NULL CONSTRAINT FK_Empleados_Sucursales REFERENCES dbo.Sucursales(id_sucursal),
    activo      BIT NOT NULL CONSTRAINT DF_Empleados_activo DEFAULT (1)
);
GO
CREATE INDEX IX_Empleados_sucursal ON dbo.Empleados(id_sucursal);
GO

-- Catalogo REPLICADO (copia maestra en Medellin).
CREATE TABLE dbo.ProductosFinancieros
(
    id_producto  INT NOT NULL CONSTRAINT PK_ProductosFinancieros PRIMARY KEY,
    nombre       NVARCHAR(80) NOT NULL CONSTRAINT UQ_Productos_nombre UNIQUE,
    categoria    VARCHAR(10)  NOT NULL CONSTRAINT CK_Productos_categoria CHECK (categoria IN ('AHORRO','CREDITO','INVERSION','SEGURO')),
    tasa_interes DECIMAL(5,2) NOT NULL CONSTRAINT CK_Productos_tasa CHECK (tasa_interes BETWEEN 0 AND 100),
    descripcion  NVARCHAR(200) NULL,
    activo       BIT NOT NULL CONSTRAINT DF_Productos_activo DEFAULT (1)
);
GO

-- Historial / auditoria propio del nodo.
CREATE TABLE dbo.Auditoria
(
    id_auditoria     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Auditoria PRIMARY KEY,
    base_datos       SYSNAME      NOT NULL,
    tabla            SYSNAME      NOT NULL,
    operacion        VARCHAR(10)  NOT NULL CONSTRAINT CK_Auditoria_operacion CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    id_registro      INT          NULL,
    datos_anteriores NVARCHAR(MAX) NULL,   -- JSON con la fila antes del cambio
    datos_nuevos     NVARCHAR(MAX) NULL,   -- JSON con la fila despues del cambio
    usuario          SYSNAME      NOT NULL CONSTRAINT DF_Auditoria_usuario DEFAULT (SUSER_SNAME()),
    fecha            DATETIME2(0) NOT NULL CONSTRAINT DF_Auditoria_fecha   DEFAULT (SYSDATETIME())
);
GO
CREATE INDEX IX_Auditoria_tabla_fecha ON dbo.Auditoria(tabla, fecha);
GO

/* Sinonimos hacia la base principal: permiten que los triggers de este
   nodo verifiquen si un registro esta siendo usado en BancoCentral. */
CREATE SYNONYM dbo.syn_CuentasCentral   FOR BancoCentral.dbo.Cuentas;
CREATE SYNONYM dbo.syn_PrestamosCentral FOR BancoCentral.dbo.Prestamos;
GO

/* ---------------------------------------------------------------------
   3.2 TRIGGERS (minimo uno por tabla)
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_Auditoria ON dbo.TiposCuenta
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'TiposCuenta',
           CASE WHEN i.id_tipo_cuenta IS NOT NULL AND d.id_tipo_cuenta IS NOT NULL THEN 'UPDATE'
                WHEN i.id_tipo_cuenta IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_tipo_cuenta, d.id_tipo_cuenta),
           (SELECT x.* FROM deleted  x WHERE x.id_tipo_cuenta = d.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_tipo_cuenta = i.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_tipo_cuenta = i.id_tipo_cuenta;
END;
GO

-- Integridad distribuida: no borrar un tipo de cuenta usado en BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_EvitarEliminacion ON dbo.TiposCuenta
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_tipo_cuenta = d.id_tipo_cuenta)
        THROW 51001, N'No se puede eliminar el tipo de cuenta: existen cuentas en BancoCentral que lo utilizan.', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Auditoria ON dbo.Sucursales
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Sucursales',
           CASE WHEN i.id_sucursal IS NOT NULL AND d.id_sucursal IS NOT NULL THEN 'UPDATE'
                WHEN i.id_sucursal IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_sucursal, d.id_sucursal),
           (SELECT x.* FROM deleted  x WHERE x.id_sucursal = d.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_sucursal = i.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_sucursal = i.id_sucursal;
END;
GO

-- Control de Sucursales: no borrar la sede central, ni sucursales con empleados o con cuentas
CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Control ON dbo.Sucursales
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted WHERE es_sede_central = 1)
        THROW 51002, N'No se puede eliminar la sede central (Medellín): gestiona todas las sedes.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.Empleados e ON e.id_sucursal = d.id_sucursal)
        THROW 51006, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_sucursal = d.id_sucursal)
        THROW 51003, N'No se puede eliminar la sucursal: tiene cuentas registradas en BancoCentral.', 1;

    DELETE s FROM dbo.Sucursales s JOIN deleted d ON d.id_sucursal = s.id_sucursal;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Empleados_Auditoria ON dbo.Empleados
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Empleados',
           CASE WHEN i.id_empleado IS NOT NULL AND d.id_empleado IS NOT NULL THEN 'UPDATE'
                WHEN i.id_empleado IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_empleado, d.id_empleado),
           (SELECT x.* FROM deleted  x WHERE x.id_empleado = d.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_empleado = i.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_empleado = i.id_empleado;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Productos_Auditoria ON dbo.ProductosFinancieros
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'ProductosFinancieros',
           CASE WHEN i.id_producto IS NOT NULL AND d.id_producto IS NOT NULL THEN 'UPDATE'
                WHEN i.id_producto IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_producto, d.id_producto),
           (SELECT x.* FROM deleted  x WHERE x.id_producto = d.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_producto = i.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_producto = i.id_producto;
END;
GO

-- Integridad distribuida: no borrar un producto usado por prestamos de BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_Productos_EvitarEliminacion ON dbo.ProductosFinancieros
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_PrestamosCentral p ON p.id_producto = d.id_producto)
        THROW 51004, N'No se puede eliminar el producto: hay préstamos en BancoCentral asociados. Desactívelo (activo = 0).', 1;
END;
GO

-- La auditoria es inmutable
CREATE OR ALTER TRIGGER dbo.tr_Auditoria_Inmutable ON dbo.Auditoria
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51005, N'El historial de auditoría es de solo lectura: no se permite UPDATE ni DELETE.', 1;
END;
GO

/* ---------------------------------------------------------------------
   3.3 PROCEDIMIENTOS CRUD DEL NODO
   --------------------------------------------------------------------- */
/* ========== TIPOS DE CUENTA (catalogo replicado) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Insertar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50),
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @id_tipo_cuenta IS NULL OR @id_tipo_cuenta <= 0
            THROW 51100, N'El id del tipo de cuenta es obligatorio (catálogo replicado: el id lo asigna la sede central).', 1;
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51101, N'El nombre del tipo de cuenta es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre OR id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese id o nombre.', 1;

        INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES (@id_tipo_cuenta, @nombre, @descripcion);
        SELECT N'Tipo de cuenta registrado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Consultar
    @id_tipo_cuenta INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_tipo_cuenta, nombre, descripcion, DB_NAME() AS nodo
        FROM dbo.TiposCuenta
        WHERE @id_tipo_cuenta IS NULL OR id_tipo_cuenta = @id_tipo_cuenta
        ORDER BY id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Actualizar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50)  = NULL,
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;
        IF @nombre IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre AND id_tipo_cuenta <> @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese nombre.', 1;

        UPDATE dbo.TiposCuenta
           SET nombre      = COALESCE(@nombre, nombre),
               descripcion = COALESCE(@descripcion, descripcion)
         WHERE id_tipo_cuenta = @id_tipo_cuenta;
        SELECT N'Tipo de cuenta actualizado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Eliminar
    @id_tipo_cuenta INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;

        DELETE FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta;  -- el trigger valida uso en BancoCentral
        SELECT N'Tipo de cuenta eliminado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== SUCURSALES (solo las de Cartagena) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Insertar
    @nombre      NVARCHAR(80),
    @ciudad      NVARCHAR(50)  = N'Cartagena',
    @direccion   NVARCHAR(150) = NULL,
    @id_sucursal INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51201, N'El nombre de la sucursal es obligatorio.', 1;
        IF ISNULL(@ciudad, N'') <> N'Cartagena'
            THROW 51202, N'Este nodo (BancoCartagena) solo administra sucursales de Cartagena. Use el Linked Server de la ciudad correspondiente.', 1;

        INSERT INTO dbo.Sucursales (nombre, ciudad, direccion, es_sede_central)
        VALUES (@nombre, @ciudad, @direccion, 0);
        SET @id_sucursal = SCOPE_IDENTITY();
        SELECT N'Sucursal registrada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Consultar
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre, s.ciudad, s.direccion,
               CASE WHEN s.es_sede_central = 1 THEN N'SEDE CENTRAL' ELSE N'Sucursal' END AS tipo_sede,
               (SELECT COUNT(*) FROM dbo.Empleados e WHERE e.id_sucursal = s.id_sucursal AND e.activo = 1) AS empleados_activos,
               DB_NAME() AS nodo
        FROM dbo.Sucursales s
        WHERE @id_sucursal IS NULL OR s.id_sucursal = @id_sucursal
        ORDER BY s.id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Actualizar
    @id_sucursal INT,
    @nombre      NVARCHAR(80)  = NULL,
    @direccion   NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;

        UPDATE dbo.Sucursales
           SET nombre    = COALESCE(@nombre, nombre),
               direccion = COALESCE(@direccion, direccion)
         WHERE id_sucursal = @id_sucursal;
        SELECT N'Sucursal actualizada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Eliminar
    @id_sucursal INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_sucursal = @id_sucursal)
            THROW 51204, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

        DELETE FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal;  -- el trigger valida sede central y cuentas
        SELECT N'Sucursal eliminada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== EMPLEADOS (de las sucursales de Cartagena) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Insertar
    @nombre      NVARCHAR(100),
    @documento   VARCHAR(20),
    @cargo       NVARCHAR(50),
    @id_sucursal INT,
    @id_empleado INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51301, N'El nombre del empleado es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE documento = @documento)
            THROW 51302, N'Ya existe un empleado con ese documento en este nodo.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Cartagena).', 1;

        INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal)
        VALUES (@nombre, @documento, @cargo, @id_sucursal);
        SET @id_empleado = SCOPE_IDENTITY();
        SELECT N'Empleado registrado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Consultar
    @id_empleado INT = NULL,
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT e.id_empleado, e.nombre, e.documento, e.cargo,
               s.nombre AS sucursal, s.ciudad,
               CASE WHEN e.activo = 1 THEN 'ACTIVO' ELSE 'INACTIVO' END AS estado,
               DB_NAME() AS nodo
        FROM dbo.Empleados e
        JOIN dbo.Sucursales s ON s.id_sucursal = e.id_sucursal
        WHERE (@id_empleado IS NULL OR e.id_empleado = @id_empleado)
          AND (@id_sucursal IS NULL OR e.id_sucursal = @id_sucursal)
        ORDER BY s.id_sucursal, e.nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Actualizar
    @id_empleado INT,
    @nombre      NVARCHAR(100) = NULL,
    @cargo       NVARCHAR(50)  = NULL,
    @id_sucursal INT = NULL,
    @activo      BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;
        IF @id_sucursal IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Cartagena).', 1;

        UPDATE dbo.Empleados
           SET nombre      = COALESCE(@nombre, nombre),
               cargo       = COALESCE(@cargo, cargo),
               id_sucursal = COALESCE(@id_sucursal, id_sucursal),
               activo      = COALESCE(@activo, activo)
         WHERE id_empleado = @id_empleado;
        SELECT N'Empleado actualizado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Eliminar
    @id_empleado INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;

        DELETE FROM dbo.Empleados WHERE id_empleado = @id_empleado;
        SELECT N'Empleado eliminado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Consulta de productos financieros (catalogo replicado) */
CREATE OR ALTER PROCEDURE dbo.sp_Producto_Consultar
    @categoria VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_producto, nombre, categoria, tasa_interes, descripcion, activo, DB_NAME() AS nodo
        FROM dbo.ProductosFinancieros
        WHERE @categoria IS NULL OR categoria = @categoria
        ORDER BY categoria, nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   3.4 DATOS INICIALES DEL NODO
   --------------------------------------------------------------------- */
-- Catalogos replicados (mismos ids en las 5 sedes)
INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES
(1, N'Ahorros',           N'Cuenta de ahorros tradicional con rendimiento mensual'),
(2, N'Corriente',         N'Cuenta corriente para manejo de chequera y pagos empresariales'),
(3, N'Nómina',            N'Cuenta de ahorros para recibir el pago de salario'),
(4, N'Ahorro programado', N'Cuenta con meta de ahorro y aportes periódicos');
GO

INSERT INTO dbo.ProductosFinancieros (id_producto, nombre, categoria, tasa_interes, descripcion) VALUES
(1, N'Crédito de libre inversión', 'CREDITO',   18.00, N'Préstamo de consumo sin destinación específica'),
(2, N'Crédito hipotecario',        'CREDITO',   11.00, N'Financiación de vivienda a largo plazo'),
(3, N'Crédito vehicular',          'CREDITO',   15.00, N'Financiación para compra de vehículo'),
(4, N'Crédito empresarial',        'CREDITO',   14.00, N'Capital de trabajo para personas jurídicas'),
(5, N'Cuenta de ahorros',          'AHORRO',     1.50, N'Rendimiento efectivo anual de la cuenta de ahorros'),
(6, N'CDT 180 días',               'INVERSION',  9.50, N'Certificado de depósito a término fijo'),
(7, N'Seguro de vida deudor',      'SEGURO',     0.00, N'Seguro obligatorio asociado a créditos');
GO

-- Sucursal principal de la ciudad (id fijo = 3)
SET IDENTITY_INSERT dbo.Sucursales ON;
INSERT INTO dbo.Sucursales (id_sucursal, nombre, ciudad, direccion, es_sede_central)
VALUES (3, N'Sucursal Cartagena', N'Cartagena', N'Av. San Martín # 8-20, Bocagrande', 0);
SET IDENTITY_INSERT dbo.Sucursales OFF;
GO

INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal) VALUES
(N'Rafael Núñez Pájaro',     '1047200006', N'Gerente de Sucursal', 3),
(N'Kelly Johanna Barrios',   '1047200007', N'Cajero',              3);
GO

PRINT N'>> Nodo BancoCartagena (Cartagena) creado correctamente.';
GO

/* #####################################################################
   NODO 4 : BancoSanAndres   (Sucursal San Andrés)  -> Linked Server SRV_SANANDRES
   ##################################################################### */
USE master;
GO
IF DB_ID(N'BancoSanAndres') IS NOT NULL
BEGIN
    ALTER DATABASE BancoSanAndres SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoSanAndres;
END
GO
CREATE DATABASE BancoSanAndres;
GO
USE BancoSanAndres;
GO

/* ---------------------------------------------------------------------
   4.1 TABLAS
   --------------------------------------------------------------------- */
-- Catalogo REPLICADO en todos los nodos (la copia maestra es la de Medellin).
-- El id es explicito (sin IDENTITY) para que sea el mismo en todas las sedes.
CREATE TABLE dbo.TiposCuenta
(
    id_tipo_cuenta INT NOT NULL CONSTRAINT PK_TiposCuenta PRIMARY KEY,
    nombre         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_TiposCuenta_nombre UNIQUE,
    descripcion    NVARCHAR(200) NULL
);
GO

-- Fragmento HORIZONTAL: este nodo solo guarda las sucursales de San Andrés.
-- IDENTITY(401,1): las sucursales nuevas de este nodo reciben ids 401, 402, ...
-- (la sucursal principal de la ciudad conserva el id 4), asi el id es unico en todo el sistema.
CREATE TABLE dbo.Sucursales
(
    id_sucursal     INT IDENTITY(401,1) NOT NULL CONSTRAINT PK_Sucursales PRIMARY KEY,
    nombre          NVARCHAR(80)  NOT NULL CONSTRAINT UQ_Sucursales_nombre UNIQUE,
    ciudad          NVARCHAR(50)  NOT NULL CONSTRAINT DF_Sucursales_ciudad DEFAULT (N'San Andrés'),
    direccion       NVARCHAR(150) NULL,
    es_sede_central BIT NOT NULL CONSTRAINT DF_Sucursales_central DEFAULT (0),
    CONSTRAINT CK_Sucursales_ciudad CHECK (ciudad = N'San Andrés')
);
GO
-- La sede central esta en Medellín: en este nodo ninguna sucursal puede serlo
ALTER TABLE dbo.Sucursales ADD CONSTRAINT CK_Sucursales_NoCentral CHECK (es_sede_central = 0);
GO

-- Fragmento HORIZONTAL: empleados de las sucursales de San Andrés.
CREATE TABLE dbo.Empleados
(
    id_empleado INT IDENTITY(4001,1) NOT NULL CONSTRAINT PK_Empleados PRIMARY KEY,
    nombre      NVARCHAR(100) NOT NULL,
    documento   VARCHAR(20)   NOT NULL CONSTRAINT UQ_Empleados_documento UNIQUE,
    cargo       NVARCHAR(50)  NOT NULL,
    id_sucursal INT NOT NULL CONSTRAINT FK_Empleados_Sucursales REFERENCES dbo.Sucursales(id_sucursal),
    activo      BIT NOT NULL CONSTRAINT DF_Empleados_activo DEFAULT (1)
);
GO
CREATE INDEX IX_Empleados_sucursal ON dbo.Empleados(id_sucursal);
GO

-- Catalogo REPLICADO (copia maestra en Medellin).
CREATE TABLE dbo.ProductosFinancieros
(
    id_producto  INT NOT NULL CONSTRAINT PK_ProductosFinancieros PRIMARY KEY,
    nombre       NVARCHAR(80) NOT NULL CONSTRAINT UQ_Productos_nombre UNIQUE,
    categoria    VARCHAR(10)  NOT NULL CONSTRAINT CK_Productos_categoria CHECK (categoria IN ('AHORRO','CREDITO','INVERSION','SEGURO')),
    tasa_interes DECIMAL(5,2) NOT NULL CONSTRAINT CK_Productos_tasa CHECK (tasa_interes BETWEEN 0 AND 100),
    descripcion  NVARCHAR(200) NULL,
    activo       BIT NOT NULL CONSTRAINT DF_Productos_activo DEFAULT (1)
);
GO

-- Historial / auditoria propio del nodo.
CREATE TABLE dbo.Auditoria
(
    id_auditoria     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Auditoria PRIMARY KEY,
    base_datos       SYSNAME      NOT NULL,
    tabla            SYSNAME      NOT NULL,
    operacion        VARCHAR(10)  NOT NULL CONSTRAINT CK_Auditoria_operacion CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    id_registro      INT          NULL,
    datos_anteriores NVARCHAR(MAX) NULL,   -- JSON con la fila antes del cambio
    datos_nuevos     NVARCHAR(MAX) NULL,   -- JSON con la fila despues del cambio
    usuario          SYSNAME      NOT NULL CONSTRAINT DF_Auditoria_usuario DEFAULT (SUSER_SNAME()),
    fecha            DATETIME2(0) NOT NULL CONSTRAINT DF_Auditoria_fecha   DEFAULT (SYSDATETIME())
);
GO
CREATE INDEX IX_Auditoria_tabla_fecha ON dbo.Auditoria(tabla, fecha);
GO

/* Sinonimos hacia la base principal: permiten que los triggers de este
   nodo verifiquen si un registro esta siendo usado en BancoCentral. */
CREATE SYNONYM dbo.syn_CuentasCentral   FOR BancoCentral.dbo.Cuentas;
CREATE SYNONYM dbo.syn_PrestamosCentral FOR BancoCentral.dbo.Prestamos;
GO

/* ---------------------------------------------------------------------
   4.2 TRIGGERS (minimo uno por tabla)
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_Auditoria ON dbo.TiposCuenta
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'TiposCuenta',
           CASE WHEN i.id_tipo_cuenta IS NOT NULL AND d.id_tipo_cuenta IS NOT NULL THEN 'UPDATE'
                WHEN i.id_tipo_cuenta IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_tipo_cuenta, d.id_tipo_cuenta),
           (SELECT x.* FROM deleted  x WHERE x.id_tipo_cuenta = d.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_tipo_cuenta = i.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_tipo_cuenta = i.id_tipo_cuenta;
END;
GO

-- Integridad distribuida: no borrar un tipo de cuenta usado en BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_EvitarEliminacion ON dbo.TiposCuenta
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_tipo_cuenta = d.id_tipo_cuenta)
        THROW 51001, N'No se puede eliminar el tipo de cuenta: existen cuentas en BancoCentral que lo utilizan.', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Auditoria ON dbo.Sucursales
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Sucursales',
           CASE WHEN i.id_sucursal IS NOT NULL AND d.id_sucursal IS NOT NULL THEN 'UPDATE'
                WHEN i.id_sucursal IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_sucursal, d.id_sucursal),
           (SELECT x.* FROM deleted  x WHERE x.id_sucursal = d.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_sucursal = i.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_sucursal = i.id_sucursal;
END;
GO

-- Control de Sucursales: no borrar la sede central, ni sucursales con empleados o con cuentas
CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Control ON dbo.Sucursales
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted WHERE es_sede_central = 1)
        THROW 51002, N'No se puede eliminar la sede central (Medellín): gestiona todas las sedes.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.Empleados e ON e.id_sucursal = d.id_sucursal)
        THROW 51006, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_sucursal = d.id_sucursal)
        THROW 51003, N'No se puede eliminar la sucursal: tiene cuentas registradas en BancoCentral.', 1;

    DELETE s FROM dbo.Sucursales s JOIN deleted d ON d.id_sucursal = s.id_sucursal;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Empleados_Auditoria ON dbo.Empleados
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Empleados',
           CASE WHEN i.id_empleado IS NOT NULL AND d.id_empleado IS NOT NULL THEN 'UPDATE'
                WHEN i.id_empleado IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_empleado, d.id_empleado),
           (SELECT x.* FROM deleted  x WHERE x.id_empleado = d.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_empleado = i.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_empleado = i.id_empleado;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Productos_Auditoria ON dbo.ProductosFinancieros
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'ProductosFinancieros',
           CASE WHEN i.id_producto IS NOT NULL AND d.id_producto IS NOT NULL THEN 'UPDATE'
                WHEN i.id_producto IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_producto, d.id_producto),
           (SELECT x.* FROM deleted  x WHERE x.id_producto = d.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_producto = i.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_producto = i.id_producto;
END;
GO

-- Integridad distribuida: no borrar un producto usado por prestamos de BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_Productos_EvitarEliminacion ON dbo.ProductosFinancieros
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_PrestamosCentral p ON p.id_producto = d.id_producto)
        THROW 51004, N'No se puede eliminar el producto: hay préstamos en BancoCentral asociados. Desactívelo (activo = 0).', 1;
END;
GO

-- La auditoria es inmutable
CREATE OR ALTER TRIGGER dbo.tr_Auditoria_Inmutable ON dbo.Auditoria
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51005, N'El historial de auditoría es de solo lectura: no se permite UPDATE ni DELETE.', 1;
END;
GO

/* ---------------------------------------------------------------------
   4.3 PROCEDIMIENTOS CRUD DEL NODO
   --------------------------------------------------------------------- */
/* ========== TIPOS DE CUENTA (catalogo replicado) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Insertar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50),
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @id_tipo_cuenta IS NULL OR @id_tipo_cuenta <= 0
            THROW 51100, N'El id del tipo de cuenta es obligatorio (catálogo replicado: el id lo asigna la sede central).', 1;
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51101, N'El nombre del tipo de cuenta es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre OR id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese id o nombre.', 1;

        INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES (@id_tipo_cuenta, @nombre, @descripcion);
        SELECT N'Tipo de cuenta registrado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Consultar
    @id_tipo_cuenta INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_tipo_cuenta, nombre, descripcion, DB_NAME() AS nodo
        FROM dbo.TiposCuenta
        WHERE @id_tipo_cuenta IS NULL OR id_tipo_cuenta = @id_tipo_cuenta
        ORDER BY id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Actualizar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50)  = NULL,
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;
        IF @nombre IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre AND id_tipo_cuenta <> @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese nombre.', 1;

        UPDATE dbo.TiposCuenta
           SET nombre      = COALESCE(@nombre, nombre),
               descripcion = COALESCE(@descripcion, descripcion)
         WHERE id_tipo_cuenta = @id_tipo_cuenta;
        SELECT N'Tipo de cuenta actualizado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Eliminar
    @id_tipo_cuenta INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;

        DELETE FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta;  -- el trigger valida uso en BancoCentral
        SELECT N'Tipo de cuenta eliminado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== SUCURSALES (solo las de San Andrés) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Insertar
    @nombre      NVARCHAR(80),
    @ciudad      NVARCHAR(50)  = N'San Andrés',
    @direccion   NVARCHAR(150) = NULL,
    @id_sucursal INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51201, N'El nombre de la sucursal es obligatorio.', 1;
        IF ISNULL(@ciudad, N'') <> N'San Andrés'
            THROW 51202, N'Este nodo (BancoSanAndres) solo administra sucursales de San Andrés. Use el Linked Server de la ciudad correspondiente.', 1;

        INSERT INTO dbo.Sucursales (nombre, ciudad, direccion, es_sede_central)
        VALUES (@nombre, @ciudad, @direccion, 0);
        SET @id_sucursal = SCOPE_IDENTITY();
        SELECT N'Sucursal registrada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Consultar
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre, s.ciudad, s.direccion,
               CASE WHEN s.es_sede_central = 1 THEN N'SEDE CENTRAL' ELSE N'Sucursal' END AS tipo_sede,
               (SELECT COUNT(*) FROM dbo.Empleados e WHERE e.id_sucursal = s.id_sucursal AND e.activo = 1) AS empleados_activos,
               DB_NAME() AS nodo
        FROM dbo.Sucursales s
        WHERE @id_sucursal IS NULL OR s.id_sucursal = @id_sucursal
        ORDER BY s.id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Actualizar
    @id_sucursal INT,
    @nombre      NVARCHAR(80)  = NULL,
    @direccion   NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;

        UPDATE dbo.Sucursales
           SET nombre    = COALESCE(@nombre, nombre),
               direccion = COALESCE(@direccion, direccion)
         WHERE id_sucursal = @id_sucursal;
        SELECT N'Sucursal actualizada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Eliminar
    @id_sucursal INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_sucursal = @id_sucursal)
            THROW 51204, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

        DELETE FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal;  -- el trigger valida sede central y cuentas
        SELECT N'Sucursal eliminada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== EMPLEADOS (de las sucursales de San Andrés) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Insertar
    @nombre      NVARCHAR(100),
    @documento   VARCHAR(20),
    @cargo       NVARCHAR(50),
    @id_sucursal INT,
    @id_empleado INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51301, N'El nombre del empleado es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE documento = @documento)
            THROW 51302, N'Ya existe un empleado con ese documento en este nodo.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (San Andrés).', 1;

        INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal)
        VALUES (@nombre, @documento, @cargo, @id_sucursal);
        SET @id_empleado = SCOPE_IDENTITY();
        SELECT N'Empleado registrado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Consultar
    @id_empleado INT = NULL,
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT e.id_empleado, e.nombre, e.documento, e.cargo,
               s.nombre AS sucursal, s.ciudad,
               CASE WHEN e.activo = 1 THEN 'ACTIVO' ELSE 'INACTIVO' END AS estado,
               DB_NAME() AS nodo
        FROM dbo.Empleados e
        JOIN dbo.Sucursales s ON s.id_sucursal = e.id_sucursal
        WHERE (@id_empleado IS NULL OR e.id_empleado = @id_empleado)
          AND (@id_sucursal IS NULL OR e.id_sucursal = @id_sucursal)
        ORDER BY s.id_sucursal, e.nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Actualizar
    @id_empleado INT,
    @nombre      NVARCHAR(100) = NULL,
    @cargo       NVARCHAR(50)  = NULL,
    @id_sucursal INT = NULL,
    @activo      BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;
        IF @id_sucursal IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (San Andrés).', 1;

        UPDATE dbo.Empleados
           SET nombre      = COALESCE(@nombre, nombre),
               cargo       = COALESCE(@cargo, cargo),
               id_sucursal = COALESCE(@id_sucursal, id_sucursal),
               activo      = COALESCE(@activo, activo)
         WHERE id_empleado = @id_empleado;
        SELECT N'Empleado actualizado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Eliminar
    @id_empleado INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;

        DELETE FROM dbo.Empleados WHERE id_empleado = @id_empleado;
        SELECT N'Empleado eliminado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Consulta de productos financieros (catalogo replicado) */
CREATE OR ALTER PROCEDURE dbo.sp_Producto_Consultar
    @categoria VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_producto, nombre, categoria, tasa_interes, descripcion, activo, DB_NAME() AS nodo
        FROM dbo.ProductosFinancieros
        WHERE @categoria IS NULL OR categoria = @categoria
        ORDER BY categoria, nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   4.4 DATOS INICIALES DEL NODO
   --------------------------------------------------------------------- */
-- Catalogos replicados (mismos ids en las 5 sedes)
INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES
(1, N'Ahorros',           N'Cuenta de ahorros tradicional con rendimiento mensual'),
(2, N'Corriente',         N'Cuenta corriente para manejo de chequera y pagos empresariales'),
(3, N'Nómina',            N'Cuenta de ahorros para recibir el pago de salario'),
(4, N'Ahorro programado', N'Cuenta con meta de ahorro y aportes periódicos');
GO

INSERT INTO dbo.ProductosFinancieros (id_producto, nombre, categoria, tasa_interes, descripcion) VALUES
(1, N'Crédito de libre inversión', 'CREDITO',   18.00, N'Préstamo de consumo sin destinación específica'),
(2, N'Crédito hipotecario',        'CREDITO',   11.00, N'Financiación de vivienda a largo plazo'),
(3, N'Crédito vehicular',          'CREDITO',   15.00, N'Financiación para compra de vehículo'),
(4, N'Crédito empresarial',        'CREDITO',   14.00, N'Capital de trabajo para personas jurídicas'),
(5, N'Cuenta de ahorros',          'AHORRO',     1.50, N'Rendimiento efectivo anual de la cuenta de ahorros'),
(6, N'CDT 180 días',               'INVERSION',  9.50, N'Certificado de depósito a término fijo'),
(7, N'Seguro de vida deudor',      'SEGURO',     0.00, N'Seguro obligatorio asociado a créditos');
GO

-- Sucursal principal de la ciudad (id fijo = 4)
SET IDENTITY_INSERT dbo.Sucursales ON;
INSERT INTO dbo.Sucursales (id_sucursal, nombre, ciudad, direccion, es_sede_central)
VALUES (4, N'Sucursal San Andrés', N'San Andrés', N'Av. Colombia # 1-19, North End', 0);
SET IDENTITY_INSERT dbo.Sucursales OFF;
GO

INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal) VALUES
(N'Bryan Archbold Hooker',   '1123200008', N'Gerente de Sucursal', 4),
(N'Shirley Robinson Pomare', '1123200009', N'Asesor Comercial',    4);
GO

PRINT N'>> Nodo BancoSanAndres (San Andrés) creado correctamente.';
GO

/* #####################################################################
   NODO 5 : BancoCali   (Sucursal Cali)  -> Linked Server SRV_CALI
   ##################################################################### */
USE master;
GO
IF DB_ID(N'BancoCali') IS NOT NULL
BEGIN
    ALTER DATABASE BancoCali SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoCali;
END
GO
CREATE DATABASE BancoCali;
GO
USE BancoCali;
GO

/* ---------------------------------------------------------------------
   5.1 TABLAS
   --------------------------------------------------------------------- */
-- Catalogo REPLICADO en todos los nodos (la copia maestra es la de Medellin).
-- El id es explicito (sin IDENTITY) para que sea el mismo en todas las sedes.
CREATE TABLE dbo.TiposCuenta
(
    id_tipo_cuenta INT NOT NULL CONSTRAINT PK_TiposCuenta PRIMARY KEY,
    nombre         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_TiposCuenta_nombre UNIQUE,
    descripcion    NVARCHAR(200) NULL
);
GO

-- Fragmento HORIZONTAL: este nodo solo guarda las sucursales de Cali.
-- IDENTITY(501,1): las sucursales nuevas de este nodo reciben ids 501, 502, ...
-- (la sucursal principal de la ciudad conserva el id 5), asi el id es unico en todo el sistema.
CREATE TABLE dbo.Sucursales
(
    id_sucursal     INT IDENTITY(501,1) NOT NULL CONSTRAINT PK_Sucursales PRIMARY KEY,
    nombre          NVARCHAR(80)  NOT NULL CONSTRAINT UQ_Sucursales_nombre UNIQUE,
    ciudad          NVARCHAR(50)  NOT NULL CONSTRAINT DF_Sucursales_ciudad DEFAULT (N'Cali'),
    direccion       NVARCHAR(150) NULL,
    es_sede_central BIT NOT NULL CONSTRAINT DF_Sucursales_central DEFAULT (0),
    CONSTRAINT CK_Sucursales_ciudad CHECK (ciudad = N'Cali')
);
GO
-- La sede central esta en Medellín: en este nodo ninguna sucursal puede serlo
ALTER TABLE dbo.Sucursales ADD CONSTRAINT CK_Sucursales_NoCentral CHECK (es_sede_central = 0);
GO

-- Fragmento HORIZONTAL: empleados de las sucursales de Cali.
CREATE TABLE dbo.Empleados
(
    id_empleado INT IDENTITY(5001,1) NOT NULL CONSTRAINT PK_Empleados PRIMARY KEY,
    nombre      NVARCHAR(100) NOT NULL,
    documento   VARCHAR(20)   NOT NULL CONSTRAINT UQ_Empleados_documento UNIQUE,
    cargo       NVARCHAR(50)  NOT NULL,
    id_sucursal INT NOT NULL CONSTRAINT FK_Empleados_Sucursales REFERENCES dbo.Sucursales(id_sucursal),
    activo      BIT NOT NULL CONSTRAINT DF_Empleados_activo DEFAULT (1)
);
GO
CREATE INDEX IX_Empleados_sucursal ON dbo.Empleados(id_sucursal);
GO

-- Catalogo REPLICADO (copia maestra en Medellin).
CREATE TABLE dbo.ProductosFinancieros
(
    id_producto  INT NOT NULL CONSTRAINT PK_ProductosFinancieros PRIMARY KEY,
    nombre       NVARCHAR(80) NOT NULL CONSTRAINT UQ_Productos_nombre UNIQUE,
    categoria    VARCHAR(10)  NOT NULL CONSTRAINT CK_Productos_categoria CHECK (categoria IN ('AHORRO','CREDITO','INVERSION','SEGURO')),
    tasa_interes DECIMAL(5,2) NOT NULL CONSTRAINT CK_Productos_tasa CHECK (tasa_interes BETWEEN 0 AND 100),
    descripcion  NVARCHAR(200) NULL,
    activo       BIT NOT NULL CONSTRAINT DF_Productos_activo DEFAULT (1)
);
GO

-- Historial / auditoria propio del nodo.
CREATE TABLE dbo.Auditoria
(
    id_auditoria     BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Auditoria PRIMARY KEY,
    base_datos       SYSNAME      NOT NULL,
    tabla            SYSNAME      NOT NULL,
    operacion        VARCHAR(10)  NOT NULL CONSTRAINT CK_Auditoria_operacion CHECK (operacion IN ('INSERT','UPDATE','DELETE')),
    id_registro      INT          NULL,
    datos_anteriores NVARCHAR(MAX) NULL,   -- JSON con la fila antes del cambio
    datos_nuevos     NVARCHAR(MAX) NULL,   -- JSON con la fila despues del cambio
    usuario          SYSNAME      NOT NULL CONSTRAINT DF_Auditoria_usuario DEFAULT (SUSER_SNAME()),
    fecha            DATETIME2(0) NOT NULL CONSTRAINT DF_Auditoria_fecha   DEFAULT (SYSDATETIME())
);
GO
CREATE INDEX IX_Auditoria_tabla_fecha ON dbo.Auditoria(tabla, fecha);
GO

/* Sinonimos hacia la base principal: permiten que los triggers de este
   nodo verifiquen si un registro esta siendo usado en BancoCentral. */
CREATE SYNONYM dbo.syn_CuentasCentral   FOR BancoCentral.dbo.Cuentas;
CREATE SYNONYM dbo.syn_PrestamosCentral FOR BancoCentral.dbo.Prestamos;
GO

/* ---------------------------------------------------------------------
   5.2 TRIGGERS (minimo uno por tabla)
   --------------------------------------------------------------------- */
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_Auditoria ON dbo.TiposCuenta
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'TiposCuenta',
           CASE WHEN i.id_tipo_cuenta IS NOT NULL AND d.id_tipo_cuenta IS NOT NULL THEN 'UPDATE'
                WHEN i.id_tipo_cuenta IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_tipo_cuenta, d.id_tipo_cuenta),
           (SELECT x.* FROM deleted  x WHERE x.id_tipo_cuenta = d.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_tipo_cuenta = i.id_tipo_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_tipo_cuenta = i.id_tipo_cuenta;
END;
GO

-- Integridad distribuida: no borrar un tipo de cuenta usado en BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_EvitarEliminacion ON dbo.TiposCuenta
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_tipo_cuenta = d.id_tipo_cuenta)
        THROW 51001, N'No se puede eliminar el tipo de cuenta: existen cuentas en BancoCentral que lo utilizan.', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Auditoria ON dbo.Sucursales
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Sucursales',
           CASE WHEN i.id_sucursal IS NOT NULL AND d.id_sucursal IS NOT NULL THEN 'UPDATE'
                WHEN i.id_sucursal IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_sucursal, d.id_sucursal),
           (SELECT x.* FROM deleted  x WHERE x.id_sucursal = d.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_sucursal = i.id_sucursal FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_sucursal = i.id_sucursal;
END;
GO

-- Control de Sucursales: no borrar la sede central, ni sucursales con empleados o con cuentas
CREATE OR ALTER TRIGGER dbo.tr_Sucursales_Control ON dbo.Sucursales
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted WHERE es_sede_central = 1)
        THROW 51002, N'No se puede eliminar la sede central (Medellín): gestiona todas las sedes.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.Empleados e ON e.id_sucursal = d.id_sucursal)
        THROW 51006, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_sucursal = d.id_sucursal)
        THROW 51003, N'No se puede eliminar la sucursal: tiene cuentas registradas en BancoCentral.', 1;

    DELETE s FROM dbo.Sucursales s JOIN deleted d ON d.id_sucursal = s.id_sucursal;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Empleados_Auditoria ON dbo.Empleados
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Empleados',
           CASE WHEN i.id_empleado IS NOT NULL AND d.id_empleado IS NOT NULL THEN 'UPDATE'
                WHEN i.id_empleado IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_empleado, d.id_empleado),
           (SELECT x.* FROM deleted  x WHERE x.id_empleado = d.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_empleado = i.id_empleado FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_empleado = i.id_empleado;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Productos_Auditoria ON dbo.ProductosFinancieros
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'ProductosFinancieros',
           CASE WHEN i.id_producto IS NOT NULL AND d.id_producto IS NOT NULL THEN 'UPDATE'
                WHEN i.id_producto IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_producto, d.id_producto),
           (SELECT x.* FROM deleted  x WHERE x.id_producto = d.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_producto = i.id_producto FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_producto = i.id_producto;
END;
GO

-- Integridad distribuida: no borrar un producto usado por prestamos de BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_Productos_EvitarEliminacion ON dbo.ProductosFinancieros
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_PrestamosCentral p ON p.id_producto = d.id_producto)
        THROW 51004, N'No se puede eliminar el producto: hay préstamos en BancoCentral asociados. Desactívelo (activo = 0).', 1;
END;
GO

-- La auditoria es inmutable
CREATE OR ALTER TRIGGER dbo.tr_Auditoria_Inmutable ON dbo.Auditoria
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51005, N'El historial de auditoría es de solo lectura: no se permite UPDATE ni DELETE.', 1;
END;
GO

/* ---------------------------------------------------------------------
   5.3 PROCEDIMIENTOS CRUD DEL NODO
   --------------------------------------------------------------------- */
/* ========== TIPOS DE CUENTA (catalogo replicado) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Insertar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50),
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF @id_tipo_cuenta IS NULL OR @id_tipo_cuenta <= 0
            THROW 51100, N'El id del tipo de cuenta es obligatorio (catálogo replicado: el id lo asigna la sede central).', 1;
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51101, N'El nombre del tipo de cuenta es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre OR id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese id o nombre.', 1;

        INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES (@id_tipo_cuenta, @nombre, @descripcion);
        SELECT N'Tipo de cuenta registrado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Consultar
    @id_tipo_cuenta INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_tipo_cuenta, nombre, descripcion, DB_NAME() AS nodo
        FROM dbo.TiposCuenta
        WHERE @id_tipo_cuenta IS NULL OR id_tipo_cuenta = @id_tipo_cuenta
        ORDER BY id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Actualizar
    @id_tipo_cuenta INT,
    @nombre         NVARCHAR(50)  = NULL,
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;
        IF @nombre IS NOT NULL AND EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre AND id_tipo_cuenta <> @id_tipo_cuenta)
            THROW 51102, N'Ya existe un tipo de cuenta con ese nombre.', 1;

        UPDATE dbo.TiposCuenta
           SET nombre      = COALESCE(@nombre, nombre),
               descripcion = COALESCE(@descripcion, descripcion)
         WHERE id_tipo_cuenta = @id_tipo_cuenta;
        SELECT N'Tipo de cuenta actualizado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Eliminar
    @id_tipo_cuenta INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 51103, N'El tipo de cuenta no existe.', 1;

        DELETE FROM dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta;  -- el trigger valida uso en BancoCentral
        SELECT N'Tipo de cuenta eliminado' AS mensaje, DB_NAME() AS nodo, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== SUCURSALES (solo las de Cali) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Insertar
    @nombre      NVARCHAR(80),
    @ciudad      NVARCHAR(50)  = N'Cali',
    @direccion   NVARCHAR(150) = NULL,
    @id_sucursal INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51201, N'El nombre de la sucursal es obligatorio.', 1;
        IF ISNULL(@ciudad, N'') <> N'Cali'
            THROW 51202, N'Este nodo (BancoCali) solo administra sucursales de Cali. Use el Linked Server de la ciudad correspondiente.', 1;

        INSERT INTO dbo.Sucursales (nombre, ciudad, direccion, es_sede_central)
        VALUES (@nombre, @ciudad, @direccion, 0);
        SET @id_sucursal = SCOPE_IDENTITY();
        SELECT N'Sucursal registrada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Consultar
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre, s.ciudad, s.direccion,
               CASE WHEN s.es_sede_central = 1 THEN N'SEDE CENTRAL' ELSE N'Sucursal' END AS tipo_sede,
               (SELECT COUNT(*) FROM dbo.Empleados e WHERE e.id_sucursal = s.id_sucursal AND e.activo = 1) AS empleados_activos,
               DB_NAME() AS nodo
        FROM dbo.Sucursales s
        WHERE @id_sucursal IS NULL OR s.id_sucursal = @id_sucursal
        ORDER BY s.id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Actualizar
    @id_sucursal INT,
    @nombre      NVARCHAR(80)  = NULL,
    @direccion   NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;

        UPDATE dbo.Sucursales
           SET nombre    = COALESCE(@nombre, nombre),
               direccion = COALESCE(@direccion, direccion)
         WHERE id_sucursal = @id_sucursal;
        SELECT N'Sucursal actualizada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Eliminar
    @id_sucursal INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe en este nodo.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_sucursal = @id_sucursal)
            THROW 51204, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

        DELETE FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal;  -- el trigger valida sede central y cuentas
        SELECT N'Sucursal eliminada' AS mensaje, DB_NAME() AS nodo, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== EMPLEADOS (de las sucursales de Cali) ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Insertar
    @nombre      NVARCHAR(100),
    @documento   VARCHAR(20),
    @cargo       NVARCHAR(50),
    @id_sucursal INT,
    @id_empleado INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51301, N'El nombre del empleado es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE documento = @documento)
            THROW 51302, N'Ya existe un empleado con ese documento en este nodo.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Cali).', 1;

        INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal)
        VALUES (@nombre, @documento, @cargo, @id_sucursal);
        SET @id_empleado = SCOPE_IDENTITY();
        SELECT N'Empleado registrado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Consultar
    @id_empleado INT = NULL,
    @id_sucursal INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT e.id_empleado, e.nombre, e.documento, e.cargo,
               s.nombre AS sucursal, s.ciudad,
               CASE WHEN e.activo = 1 THEN 'ACTIVO' ELSE 'INACTIVO' END AS estado,
               DB_NAME() AS nodo
        FROM dbo.Empleados e
        JOIN dbo.Sucursales s ON s.id_sucursal = e.id_sucursal
        WHERE (@id_empleado IS NULL OR e.id_empleado = @id_empleado)
          AND (@id_sucursal IS NULL OR e.id_sucursal = @id_sucursal)
        ORDER BY s.id_sucursal, e.nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Actualizar
    @id_empleado INT,
    @nombre      NVARCHAR(100) = NULL,
    @cargo       NVARCHAR(50)  = NULL,
    @id_sucursal INT = NULL,
    @activo      BIT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;
        IF @id_sucursal IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no pertenece a este nodo (Cali).', 1;

        UPDATE dbo.Empleados
           SET nombre      = COALESCE(@nombre, nombre),
               cargo       = COALESCE(@cargo, cargo),
               id_sucursal = COALESCE(@id_sucursal, id_sucursal),
               activo      = COALESCE(@activo, activo)
         WHERE id_empleado = @id_empleado;
        SELECT N'Empleado actualizado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Empleado_Eliminar
    @id_empleado INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_empleado = @id_empleado)
            THROW 51304, N'El empleado no existe en este nodo.', 1;

        DELETE FROM dbo.Empleados WHERE id_empleado = @id_empleado;
        SELECT N'Empleado eliminado' AS mensaje, DB_NAME() AS nodo, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Consulta de productos financieros (catalogo replicado) */
CREATE OR ALTER PROCEDURE dbo.sp_Producto_Consultar
    @categoria VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_producto, nombre, categoria, tasa_interes, descripcion, activo, DB_NAME() AS nodo
        FROM dbo.ProductosFinancieros
        WHERE @categoria IS NULL OR categoria = @categoria
        ORDER BY categoria, nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* ---------------------------------------------------------------------
   5.4 DATOS INICIALES DEL NODO
   --------------------------------------------------------------------- */
-- Catalogos replicados (mismos ids en las 5 sedes)
INSERT INTO dbo.TiposCuenta (id_tipo_cuenta, nombre, descripcion) VALUES
(1, N'Ahorros',           N'Cuenta de ahorros tradicional con rendimiento mensual'),
(2, N'Corriente',         N'Cuenta corriente para manejo de chequera y pagos empresariales'),
(3, N'Nómina',            N'Cuenta de ahorros para recibir el pago de salario'),
(4, N'Ahorro programado', N'Cuenta con meta de ahorro y aportes periódicos');
GO

INSERT INTO dbo.ProductosFinancieros (id_producto, nombre, categoria, tasa_interes, descripcion) VALUES
(1, N'Crédito de libre inversión', 'CREDITO',   18.00, N'Préstamo de consumo sin destinación específica'),
(2, N'Crédito hipotecario',        'CREDITO',   11.00, N'Financiación de vivienda a largo plazo'),
(3, N'Crédito vehicular',          'CREDITO',   15.00, N'Financiación para compra de vehículo'),
(4, N'Crédito empresarial',        'CREDITO',   14.00, N'Capital de trabajo para personas jurídicas'),
(5, N'Cuenta de ahorros',          'AHORRO',     1.50, N'Rendimiento efectivo anual de la cuenta de ahorros'),
(6, N'CDT 180 días',               'INVERSION',  9.50, N'Certificado de depósito a término fijo'),
(7, N'Seguro de vida deudor',      'SEGURO',     0.00, N'Seguro obligatorio asociado a créditos');
GO

-- Sucursal principal de la ciudad (id fijo = 5)
SET IDENTITY_INSERT dbo.Sucursales ON;
INSERT INTO dbo.Sucursales (id_sucursal, nombre, ciudad, direccion, es_sede_central)
VALUES (5, N'Sucursal Cali', N'Cali', N'Av. 6N # 23-45, Granada', 0);
SET IDENTITY_INSERT dbo.Sucursales OFF;
GO

INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal) VALUES
(N'Óscar Iván Caicedo',      '1144200010', N'Gerente de Sucursal', 5),
(N'Yuliana Mina Carabalí',   '1144200011', N'Cajero',              5);
GO

PRINT N'>> Nodo BancoCali (Cali) creado correctamente.';
GO


-- #####################################################################
-- ARCHIVO: 02_BD_Principal.sql
-- #####################################################################
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


-- #####################################################################
-- ARCHIVO: 03_Linked_Server.sql
-- #####################################################################
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


-- #####################################################################
-- ARCHIVO: 04_Funciones.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 04 : FUNCIONES DEFINIDAS POR EL USUARIO (BancoCentral)
     Escalares (2):
       1. fn_CalcularTotalPrestamo     -> total a pagar de un prestamo
       2. fn_SaldoTotalCliente         -> suma de saldos de un cliente
     De tabla (4):
       3. fn_ResumenFinancieroCliente  -> cuentas, saldo, prestamos, deuda   (Consulta 6)
       4. fn_CuentasConMasDeNTransacciones                                   (Consulta 10)
       5. fn_DetectarAnomaliasRetiros  -> muchos retiros en poco tiempo      (Consulta 11)
       6. fn_ClientesConProductosYSaldoMayorA                                (Consulta 13)
   ===================================================================== */
USE BancoCentral;
GO

/* ---------------------------------------------------------------------
   1. ESCALAR: Total a pagar de un prestamo (interes simple anual)
      total = monto * (1 + (interes/100) * (plazo/12))
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_CalcularTotalPrestamo
(
    @monto   DECIMAL(18,2),
    @interes DECIMAL(5,2),   -- tasa anual en %
    @plazo   INT             -- meses
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    IF @monto IS NULL OR @interes IS NULL OR @plazo IS NULL RETURN NULL;
    RETURN ROUND(@monto * (1 + (@interes / 100.0) * (@plazo / 12.0)), 2);
END;
GO

/* ---------------------------------------------------------------------
   2. ESCALAR: Saldo total de un cliente (todas sus cuentas no cerradas)
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_SaldoTotalCliente
(
    @id_cliente INT
)
RETURNS DECIMAL(18,2)
AS
BEGIN
    DECLARE @saldo DECIMAL(18,2);

    SELECT @saldo = SUM(saldo)
    FROM dbo.Cuentas
    WHERE id_cliente = @id_cliente
      AND estado <> 'CERRADA';

    RETURN ISNULL(@saldo, 0);
END;
GO

/* ---------------------------------------------------------------------
   3. TABLA: Resumen financiero del cliente  (CONSULTA 6)
      @id_cliente = NULL devuelve el resumen de todos los clientes.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_ResumenFinancieroCliente
(
    @id_cliente INT = NULL
)
RETURNS TABLE
AS
RETURN
(
    SELECT  c.id_cliente,
            c.nombre,
            c.documento,
            c.tipo_cliente,
            c.estado,
            cu.cantidad_cuentas,
            cu.cuentas_activas,
            cu.saldo_total,
            pr.total_prestamos,
            pr.prestamos_activos,
            pr.monto_prestado,
            pr.total_pagado,
            pr.deuda_activa,
            CAST(cu.saldo_total - pr.deuda_activa AS DECIMAL(18,2)) AS patrimonio_neto
    FROM dbo.Clientes c
    CROSS APPLY (
        SELECT COUNT(*)                                                   AS cantidad_cuentas,
               ISNULL(SUM(CASE WHEN x.estado = 'ACTIVA' THEN 1 ELSE 0 END), 0) AS cuentas_activas,
               CAST(ISNULL(SUM(CASE WHEN x.estado <> 'CERRADA' THEN x.saldo END), 0) AS DECIMAL(18,2)) AS saldo_total
        FROM dbo.Cuentas x
        WHERE x.id_cliente = c.id_cliente
    ) cu
    CROSS APPLY (
        SELECT COUNT(*)                                                         AS total_prestamos,
               ISNULL(SUM(CASE WHEN p.estado IN ('ACTIVO','MORA') THEN 1 ELSE 0 END), 0) AS prestamos_activos,
               CAST(ISNULL(SUM(p.monto), 0) AS DECIMAL(18,2))                   AS monto_prestado,
               CAST(ISNULL(SUM(pg.pagado), 0) AS DECIMAL(18,2))                 AS total_pagado,
               CAST(ISNULL(SUM(CASE WHEN p.estado IN ('ACTIVO','MORA') THEN p.saldo_pendiente END), 0) AS DECIMAL(18,2)) AS deuda_activa
        FROM dbo.Prestamos p
        OUTER APPLY (SELECT SUM(g.monto) AS pagado FROM dbo.Pagos g WHERE g.id_prestamo = p.id_prestamo) pg
        WHERE p.id_cliente = c.id_cliente
    ) pr
    WHERE @id_cliente IS NULL OR c.id_cliente = @id_cliente
);
GO

/* ---------------------------------------------------------------------
   4. TABLA: Cuentas con mas de N transacciones en un periodo (CONSULTA 10)
      Cuenta las transacciones originadas en la cuenta y las transferencias
      recibidas.
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_CuentasConMasDeNTransacciones
(
    @n           INT,
    @fecha_desde DATE,
    @fecha_hasta DATE
)
RETURNS TABLE
AS
RETURN
(
    WITH movimientos AS
    (
        SELECT id_cuenta, tipo, monto
        FROM dbo.Transacciones
        WHERE fecha >= @fecha_desde AND fecha < DATEADD(DAY, 1, @fecha_hasta)
        UNION ALL
        SELECT id_cuenta_destino, 'TRANSFERENCIA_RECIBIDA', monto
        FROM dbo.Transacciones
        WHERE tipo = 'TRANSFERENCIA'
          AND fecha >= @fecha_desde AND fecha < DATEADD(DAY, 1, @fecha_hasta)
    )
    SELECT  cu.id_cuenta,
            cu.numero_cuenta,
            cl.nombre                                                         AS cliente,
            COUNT(*)                                                          AS total_transacciones,
            SUM(CASE WHEN m.tipo = 'DEPOSITO'               THEN 1 ELSE 0 END) AS depositos,
            SUM(CASE WHEN m.tipo = 'RETIRO'                 THEN 1 ELSE 0 END) AS retiros,
            SUM(CASE WHEN m.tipo = 'TRANSFERENCIA'          THEN 1 ELSE 0 END) AS transferencias_enviadas,
            SUM(CASE WHEN m.tipo = 'TRANSFERENCIA_RECIBIDA' THEN 1 ELSE 0 END) AS transferencias_recibidas,
            CAST(SUM(m.monto) AS DECIMAL(18,2))                               AS monto_movido
    FROM movimientos m
    JOIN dbo.Cuentas  cu ON cu.id_cuenta  = m.id_cuenta
    JOIN dbo.Clientes cl ON cl.id_cliente = cu.id_cliente
    GROUP BY cu.id_cuenta, cu.numero_cuenta, cl.nombre
    HAVING COUNT(*) > @n
);
GO

/* ---------------------------------------------------------------------
   5. TABLA: Deteccion de anomalias (CONSULTA 11)
      Una cuenta es sospechosa si registra @min_retiros o mas RETIROS
      dentro de una ventana de @ventana_minutos minutos.
      Para cada retiro se abre una ventana [fecha, fecha + ventana) y se
      cuentan los retiros de la misma cuenta que caen dentro (self-join).
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_DetectarAnomaliasRetiros
(
    @min_retiros     INT,
    @ventana_minutos INT
)
RETURNS TABLE
AS
RETURN
(
    WITH ventanas AS
    (
        SELECT  r.id_cuenta,
                r.id_transaccion,
                r.fecha        AS inicio_ventana,
                MAX(r2.fecha)  AS fin_ventana,
                COUNT(*)       AS retiros_en_ventana,
                SUM(r2.monto)  AS monto_en_ventana
        FROM dbo.Transacciones r
        JOIN dbo.Transacciones r2
          ON  r2.id_cuenta = r.id_cuenta
          AND r2.tipo      = 'RETIRO'
          AND r2.fecha    >= r.fecha
          AND r2.fecha     < DATEADD(MINUTE, @ventana_minutos, r.fecha)
        WHERE r.tipo = 'RETIRO'
        GROUP BY r.id_cuenta, r.id_transaccion, r.fecha
        HAVING COUNT(*) >= @min_retiros
    )
    SELECT  cu.id_cuenta,
            cu.numero_cuenta,
            cl.nombre                                    AS cliente,
            cl.telefono,
            MIN(v.inicio_ventana)                        AS primera_alerta,
            MAX(v.fin_ventana)                           AS ultimo_retiro_sospechoso,
            MAX(v.retiros_en_ventana)                    AS max_retiros_en_ventana,
            CAST(MAX(v.monto_en_ventana) AS DECIMAL(18,2)) AS max_monto_en_ventana,
            CASE WHEN MAX(v.retiros_en_ventana) >= @min_retiros * 2 THEN 'ALTO' ELSE 'MEDIO' END AS nivel_riesgo
    FROM ventanas v
    JOIN dbo.Cuentas  cu ON cu.id_cuenta  = v.id_cuenta
    JOIN dbo.Clientes cl ON cl.id_cliente = cu.id_cliente
    GROUP BY cu.id_cuenta, cu.numero_cuenta, cl.nombre, cl.telefono
);
GO

/* ---------------------------------------------------------------------
   6. TABLA: Clientes con cuentas activas, prestamos activos y saldo
      mayor a un valor dado (CONSULTA 13)
   --------------------------------------------------------------------- */
CREATE OR ALTER FUNCTION dbo.fn_ClientesConProductosYSaldoMayorA
(
    @saldo_minimo DECIMAL(18,2)
)
RETURNS TABLE
AS
RETURN
(
    SELECT  r.id_cliente,
            r.nombre,
            r.documento,
            r.cuentas_activas,
            r.prestamos_activos,
            r.saldo_total,
            r.deuda_activa
    FROM dbo.fn_ResumenFinancieroCliente(NULL) r
    WHERE r.estado            = 'ACTIVO'
      AND r.cuentas_activas   > 0
      AND r.prestamos_activos > 0
      AND r.saldo_total       > @saldo_minimo
);
GO

PRINT N'>> Funciones creadas correctamente.';
GO


-- #####################################################################
-- ARCHIVO: 05_Triggers.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 05 : TRIGGERS DE LA BASE PRINCIPAL (BancoCentral)
   (Los triggers de los nodos de sucursal estan en 01_BD_Remotas_Sucursales.sql)

   Tabla          Trigger                                   Proposito
   -------------  ----------------------------------------  ------------------------------------------
   Clientes       tr_Clientes_Auditoria                     Historial en BancoMedellin.Auditoria (nodo sede central)
                  tr_Clientes_ControlEliminacion (INSTEAD)  Borrado logico / fisico controlado
                  tr_Clientes_ValidarInactivacion           No inactivar clientes con productos vigentes
   Cuentas        tr_Cuentas_Auditoria                      Historial
                  tr_Cuentas_Integridad                     Integridad distribuida + reglas de saldo
                  tr_Cuentas_EvitarEliminacionConSaldo      (INSTEAD OF DELETE) REQUISITO del enunciado
   Transacciones  tr_Transacciones_ActualizarSaldo          REQUISITO: actualiza saldo automaticamente
                  tr_Transacciones_Auditoria                Historial
   Prestamos      tr_Prestamos_Integridad                   REQUISITO: control de integridad en prestamos
                  tr_Prestamos_ControlEliminacion (INSTEAD) No borrar prestamos con pagos
                  tr_Prestamos_Auditoria                    Historial
   Pagos          tr_Pagos_ActualizarPrestamo               Descuenta el pago del saldo del prestamo
                  tr_Pagos_Auditoria                        Historial
   ===================================================================== */
USE BancoCentral;
GO

/* =====================================================================
   CLIENTES
   ===================================================================== */
CREATE OR ALTER TRIGGER dbo.tr_Clientes_Auditoria ON dbo.Clientes
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.syn_Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Clientes',
           CASE WHEN i.id_cliente IS NOT NULL AND d.id_cliente IS NOT NULL THEN 'UPDATE'
                WHEN i.id_cliente IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_cliente, d.id_cliente),
           (SELECT x.* FROM deleted  x WHERE x.id_cliente = d.id_cliente FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_cliente = i.id_cliente FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_cliente = i.id_cliente;
END;
GO

/* Un DELETE sobre Clientes:
   - Falla si el cliente tiene cuentas abiertas o prestamos vigentes.
   - Si el cliente tiene historial (cuentas cerradas / prestamos pagados)
     se hace BORRADO LOGICO (estado = 'INACTIVO') para no perder trazabilidad.
   - Si nunca tuvo productos, se borra fisicamente. */
CREATE OR ALTER TRIGGER dbo.tr_Clientes_ControlEliminacion ON dbo.Clientes
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.Cuentas c ON c.id_cliente = d.id_cliente WHERE c.estado <> 'CERRADA')
        THROW 50101, N'No se puede eliminar el cliente: tiene cuentas abiertas. Ciérrelas primero.', 1;

    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.Prestamos p ON p.id_cliente = d.id_cliente WHERE p.estado IN ('ACTIVO','MORA'))
        THROW 50102, N'No se puede eliminar el cliente: tiene préstamos vigentes (ACTIVO/MORA).', 1;

    -- Con historial -> borrado logico
    UPDATE c SET c.estado = 'INACTIVO'
    FROM dbo.Clientes c
    JOIN deleted d ON d.id_cliente = c.id_cliente
    WHERE EXISTS (SELECT 1 FROM dbo.Cuentas   x WHERE x.id_cliente = c.id_cliente)
       OR EXISTS (SELECT 1 FROM dbo.Prestamos x WHERE x.id_cliente = c.id_cliente);

    -- Sin historial -> borrado fisico
    DELETE c
    FROM dbo.Clientes c
    JOIN deleted d ON d.id_cliente = c.id_cliente
    WHERE NOT EXISTS (SELECT 1 FROM dbo.Cuentas   x WHERE x.id_cliente = c.id_cliente)
      AND NOT EXISTS (SELECT 1 FROM dbo.Prestamos x WHERE x.id_cliente = c.id_cliente);
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Clientes_ValidarInactivacion ON dbo.Clientes
AFTER UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    IF EXISTS (
        SELECT 1
        FROM inserted i
        JOIN deleted  d ON d.id_cliente = i.id_cliente
        WHERE i.estado = 'INACTIVO' AND d.estado = 'ACTIVO'
          AND (   EXISTS (SELECT 1 FROM dbo.Cuentas   c WHERE c.id_cliente = i.id_cliente AND c.estado <> 'CERRADA')
               OR EXISTS (SELECT 1 FROM dbo.Prestamos p WHERE p.id_cliente = i.id_cliente AND p.estado IN ('ACTIVO','MORA'))))
        THROW 50103, N'No se puede inactivar el cliente: tiene cuentas abiertas o préstamos vigentes.', 1;
END;
GO

/* =====================================================================
   CUENTAS
   ===================================================================== */
CREATE OR ALTER TRIGGER dbo.tr_Cuentas_Auditoria ON dbo.Cuentas
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.syn_Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Cuentas',
           CASE WHEN i.id_cuenta IS NOT NULL AND d.id_cuenta IS NOT NULL THEN 'UPDATE'
                WHEN i.id_cuenta IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_cuenta, d.id_cuenta),
           (SELECT x.* FROM deleted  x WHERE x.id_cuenta = d.id_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_cuenta = i.id_cuenta FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_cuenta = i.id_cuenta;
END;
GO

/* Integridad referencial DISTRIBUIDA + reglas de negocio del saldo.
   (No es posible crear FOREIGN KEY entre dos bases de datos/servidores,
    por eso la validacion contra los nodos de sucursal se hace en el trigger.) */
CREATE OR ALTER TRIGGER dbo.tr_Cuentas_Integridad ON dbo.Cuentas
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    DECLARE @es_insert BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM deleted) THEN 1 ELSE 0 END;

    -- 1. El tipo de cuenta debe existir en la base remota
    IF EXISTS (SELECT 1 FROM inserted i
               WHERE NOT EXISTS (SELECT 1 FROM dbo.syn_TiposCuenta t WHERE t.id_tipo_cuenta = i.id_tipo_cuenta))
        THROW 50201, N'El tipo de cuenta no existe en el catálogo de las sucursales (BancoMedellin.dbo.TiposCuenta).', 1;

    -- 2. La sucursal debe existir en alguno de los 5 nodos (vista que une los fragmentos)
    IF EXISTS (SELECT 1 FROM inserted i
               WHERE NOT EXISTS (SELECT 1 FROM dbo.vw_Sucursales s WHERE s.id_sucursal = i.id_sucursal))
        THROW 50202, N'La sucursal no existe en ninguno de los nodos de sucursal (Medellín, Bogotá, Cartagena, San Andrés, Cali).', 1;

    -- 3. Solo clientes ACTIVOS pueden recibir cuentas nuevas (o ser nuevos titulares)
    IF EXISTS (SELECT 1
               FROM inserted i
               LEFT JOIN deleted d  ON d.id_cuenta  = i.id_cuenta
               JOIN dbo.Clientes c ON c.id_cliente = i.id_cliente
               WHERE c.estado <> 'ACTIVO' AND (d.id_cuenta IS NULL OR d.id_cliente <> i.id_cliente))
        THROW 50203, N'El cliente está INACTIVO: no se le pueden asignar cuentas.', 1;

    -- 4. Toda cuenta nace con saldo 0 (el saldo inicial entra como DEPOSITO)
    IF @es_insert = 1 AND EXISTS (SELECT 1 FROM inserted WHERE saldo <> 0)
        THROW 50204, N'Una cuenta nueva debe crearse con saldo 0. El saldo inicial se registra como un depósito de apertura.', 1;

    -- 5. El saldo SOLO lo modifica el trigger de Transacciones (nivel de anidamiento > 1)
    IF @es_insert = 0 AND TRIGGER_NESTLEVEL() = 1
       AND EXISTS (SELECT 1 FROM inserted i JOIN deleted d ON d.id_cuenta = i.id_cuenta WHERE i.saldo <> d.saldo)
        THROW 50205, N'El saldo no se puede modificar directamente: registre un depósito, retiro o transferencia.', 1;

    -- 6. No se puede cerrar una cuenta que todavia tiene dinero
    IF EXISTS (SELECT 1 FROM inserted WHERE estado = 'CERRADA' AND saldo > 0)
        THROW 50206, N'No se puede cerrar una cuenta con saldo. Retire o transfiera el saldo primero.', 1;
END;
GO

/* REQUISITO: Evitar eliminacion de cuentas con saldo.
   - Si saldo > 0  -> error.
   - Si saldo = 0 y tiene transacciones -> se CIERRA (borrado logico, conserva historial).
   - Si saldo = 0 y no tiene transacciones -> se borra fisicamente. */
CREATE OR ALTER TRIGGER dbo.tr_Cuentas_EvitarEliminacionConSaldo ON dbo.Cuentas
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted WHERE saldo > 0)
    BEGIN
        DECLARE @msg NVARCHAR(400);
        SELECT TOP (1) @msg = CONCAT(N'No se puede eliminar la cuenta ', numero_cuenta,
                                     N': tiene un saldo de $', FORMAT(saldo, 'N2'),
                                     N'. Retire o transfiera el saldo primero.')
        FROM deleted WHERE saldo > 0;
        THROW 50207, @msg, 1;
    END;

    -- Con historial -> cierre logico
    UPDATE c SET c.estado = 'CERRADA'
    FROM dbo.Cuentas c
    JOIN deleted d ON d.id_cuenta = c.id_cuenta
    WHERE EXISTS (SELECT 1 FROM dbo.Transacciones t WHERE t.id_cuenta = c.id_cuenta OR t.id_cuenta_destino = c.id_cuenta);

    -- Sin historial -> borrado fisico
    DELETE c
    FROM dbo.Cuentas c
    JOIN deleted d ON d.id_cuenta = c.id_cuenta
    WHERE NOT EXISTS (SELECT 1 FROM dbo.Transacciones t WHERE t.id_cuenta = c.id_cuenta OR t.id_cuenta_destino = c.id_cuenta);
END;
GO

/* =====================================================================
   TRANSACCIONES
   ===================================================================== */

/* REQUISITO: Actualizar saldo automaticamente al insertar transacciones.
   - DEPOSITO       : +monto en la cuenta.
   - RETIRO         : -monto en la cuenta.
   - TRANSFERENCIA  : -monto en la cuenta origen y +monto en la destino.
   - DELETE (anulacion) aplica el efecto contrario.
   - Valida fondos: ningun saldo puede quedar negativo.
   El calculo es por conjuntos (soporta INSERT de varias filas). */
CREATE OR ALTER TRIGGER dbo.tr_Transacciones_ActualizarSaldo ON dbo.Transacciones
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    DECLARE @es_insert BIT = CASE WHEN EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) THEN 1 ELSE 0 END;
    DECLARE @es_update BIT = CASE WHEN EXISTS (SELECT 1 FROM inserted) AND EXISTS (SELECT 1 FROM deleted)     THEN 1 ELSE 0 END;
    DECLARE @msg NVARCHAR(400);

    -- 1. Una transaccion registrada es inmutable (solo puede cambiar su descripcion)
    IF @es_update = 1
    BEGIN
        IF EXISTS (SELECT 1
                   FROM inserted i
                   JOIN deleted  d ON d.id_transaccion = i.id_transaccion
                   WHERE i.id_cuenta <> d.id_cuenta OR i.tipo <> d.tipo OR i.monto <> d.monto OR i.fecha <> d.fecha
                      OR ISNULL(i.id_cuenta_destino, -1) <> ISNULL(d.id_cuenta_destino, -1))
            THROW 50301, N'Una transacción registrada no se puede modificar (solo su descripción). Anúlela y registre una nueva.', 1;
        RETURN;   -- solo cambio la descripcion: no afecta saldos
    END;

    -- 2. Solo se registran movimientos sobre cuentas ACTIVAS (origen y destino)
    IF @es_insert = 1 AND EXISTS (SELECT 1
                                  FROM inserted i
                                  JOIN dbo.Cuentas c ON c.id_cuenta = i.id_cuenta OR c.id_cuenta = i.id_cuenta_destino
                                  WHERE c.estado <> 'ACTIVA')
        THROW 50302, N'La cuenta origen o destino no está ACTIVA. No se puede registrar la transacción.', 1;

    -- 3. Efecto neto de los movimientos sobre cada cuenta
    DECLARE @efecto TABLE (id_cuenta INT PRIMARY KEY, delta DECIMAL(18,2) NOT NULL);

    INSERT INTO @efecto (id_cuenta, delta)
    SELECT m.id_cuenta, SUM(m.delta)
    FROM (
        SELECT i.id_cuenta,         CASE WHEN i.tipo = 'DEPOSITO' THEN  i.monto ELSE -i.monto END AS delta FROM inserted i
        UNION ALL
        SELECT i.id_cuenta_destino, i.monto  FROM inserted i WHERE i.tipo = 'TRANSFERENCIA'
        UNION ALL
        SELECT d.id_cuenta,         CASE WHEN d.tipo = 'DEPOSITO' THEN -d.monto ELSE  d.monto END FROM deleted d
        UNION ALL
        SELECT d.id_cuenta_destino, -d.monto FROM deleted d WHERE d.tipo = 'TRANSFERENCIA'
    ) m
    GROUP BY m.id_cuenta;

    -- 4. Validar fondos: no se permite saldo negativo ni transferencias sin fondos
    IF EXISTS (SELECT 1 FROM dbo.Cuentas c JOIN @efecto e ON e.id_cuenta = c.id_cuenta WHERE c.saldo + e.delta < 0)
    BEGIN
        SELECT TOP (1) @msg = CONCAT(N'Fondos insuficientes en la cuenta ', c.numero_cuenta,
                                     N'. Saldo disponible: $', FORMAT(c.saldo, 'N2'),
                                     N'. Valor requerido: $', FORMAT(-e.delta, 'N2'), N'.')
        FROM dbo.Cuentas c JOIN @efecto e ON e.id_cuenta = c.id_cuenta
        WHERE c.saldo + e.delta < 0;
        THROW 50303, @msg, 1;
    END;

    -- 5. Aplicar el movimiento a los saldos
    UPDATE c
       SET c.saldo = c.saldo + e.delta
    FROM dbo.Cuentas c
    JOIN @efecto e ON e.id_cuenta = c.id_cuenta
    WHERE e.delta <> 0;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Transacciones_Auditoria ON dbo.Transacciones
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.syn_Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Transacciones',
           CASE WHEN i.id_transaccion IS NOT NULL AND d.id_transaccion IS NOT NULL THEN 'UPDATE'
                WHEN i.id_transaccion IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_transaccion, d.id_transaccion),
           (SELECT x.* FROM deleted  x WHERE x.id_transaccion = d.id_transaccion FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_transaccion = i.id_transaccion FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_transaccion = i.id_transaccion;
END;
GO

/* =====================================================================
   PRESTAMOS
   ===================================================================== */

/* REQUISITO: Control de integridad en prestamos. */
CREATE OR ALTER TRIGGER dbo.tr_Prestamos_Integridad ON dbo.Prestamos
AFTER INSERT, UPDATE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) RETURN;

    DECLARE @es_insert BIT = CASE WHEN NOT EXISTS (SELECT 1 FROM deleted) THEN 1 ELSE 0 END;

    -- 1. Solo clientes ACTIVOS pueden recibir prestamos
    IF EXISTS (SELECT 1
               FROM inserted i
               LEFT JOIN deleted d  ON d.id_prestamo = i.id_prestamo
               JOIN dbo.Clientes c ON c.id_cliente  = i.id_cliente
               WHERE c.estado <> 'ACTIVO' AND (d.id_prestamo IS NULL OR d.id_cliente <> i.id_cliente))
        THROW 50401, N'No se puede otorgar el préstamo: el cliente está INACTIVO.', 1;

    -- 2. El producto (BD remota) debe existir, ser de categoria CREDITO y estar activo
    IF EXISTS (SELECT 1
               FROM inserted i
               LEFT JOIN deleted d ON d.id_prestamo = i.id_prestamo
               WHERE i.id_producto IS NOT NULL
                 AND (d.id_prestamo IS NULL OR ISNULL(d.id_producto, -1) <> i.id_producto)
                 AND NOT EXISTS (SELECT 1 FROM dbo.syn_ProductosFinancieros pf
                                 WHERE pf.id_producto = i.id_producto AND pf.categoria = 'CREDITO' AND pf.activo = 1))
        THROW 50402, N'El producto financiero no existe en el catálogo de las sucursales, no es de categoría CREDITO o está inactivo.', 1;

    -- 3. Un prestamo nuevo siempre nace ACTIVO
    IF @es_insert = 1 AND EXISTS (SELECT 1 FROM inserted WHERE estado <> 'ACTIVO')
        THROW 50403, N'Un préstamo nuevo debe registrarse en estado ACTIVO.', 1;

    -- 4. Monto, interes, plazo y titular no cambian si ya existen pagos
    IF @es_insert = 0 AND EXISTS (SELECT 1
                                  FROM inserted i
                                  JOIN deleted  d ON d.id_prestamo = i.id_prestamo
                                  WHERE (i.monto <> d.monto OR i.interes <> d.interes OR i.plazo <> d.plazo OR i.id_cliente <> d.id_cliente)
                                    AND EXISTS (SELECT 1 FROM dbo.Pagos p WHERE p.id_prestamo = i.id_prestamo))
        THROW 50404, N'No se puede cambiar monto, interés, plazo o titular de un préstamo que ya tiene pagos.', 1;

    -- 5. El saldo pendiente no se edita a mano (solo lo cambia el trigger de Pagos)
    IF @es_insert = 0 AND TRIGGER_NESTLEVEL() = 1
       AND EXISTS (SELECT 1
                   FROM inserted i
                   JOIN deleted  d ON d.id_prestamo = i.id_prestamo
                   WHERE i.saldo_pendiente <> d.saldo_pendiente
                     AND i.monto = d.monto AND i.interes = d.interes AND i.plazo = d.plazo)
        THROW 50405, N'El saldo pendiente no se modifica manualmente: registre un pago.', 1;

    -- 6. Maximo 3 prestamos vigentes por cliente
    IF EXISTS (SELECT 1
               FROM dbo.Prestamos p
               WHERE p.id_cliente IN (SELECT id_cliente FROM inserted)
                 AND p.estado IN ('ACTIVO','MORA')
               GROUP BY p.id_cliente
               HAVING COUNT(*) > 3)
        THROW 50406, N'El cliente ya tiene el máximo permitido de 3 préstamos vigentes (ACTIVO/MORA).', 1;

    -- 7. Calcular el saldo pendiente (capital + intereses) de prestamos nuevos o reliquidados
    UPDATE p
       SET p.saldo_pendiente = dbo.fn_CalcularTotalPrestamo(p.monto, p.interes, p.plazo)
    FROM dbo.Prestamos p
    JOIN inserted i      ON i.id_prestamo = p.id_prestamo
    LEFT JOIN deleted d  ON d.id_prestamo = i.id_prestamo
    WHERE d.id_prestamo IS NULL
       OR i.monto <> d.monto OR i.interes <> d.interes OR i.plazo <> d.plazo;

    -- 8. Coherencia entre estado y saldo pendiente
    IF EXISTS (SELECT 1 FROM dbo.Prestamos p JOIN inserted i ON i.id_prestamo = p.id_prestamo
               WHERE p.estado = 'PAGADO' AND p.saldo_pendiente > 0)
        THROW 50407, N'Un préstamo solo puede quedar PAGADO cuando su saldo pendiente es 0.', 1;

    IF EXISTS (SELECT 1 FROM dbo.Prestamos p JOIN inserted i ON i.id_prestamo = p.id_prestamo
               WHERE p.estado IN ('ACTIVO','MORA') AND p.saldo_pendiente = 0)
        THROW 50408, N'Un préstamo sin saldo pendiente no puede estar ACTIVO ni en MORA.', 1;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Prestamos_ControlEliminacion ON dbo.Prestamos
INSTEAD OF DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    IF EXISTS (SELECT 1 FROM deleted d WHERE EXISTS (SELECT 1 FROM dbo.Pagos p WHERE p.id_prestamo = d.id_prestamo))
        THROW 50409, N'No se puede eliminar un préstamo con pagos registrados. Puede cambiar su estado a CANCELADO.', 1;

    DELETE p
    FROM dbo.Prestamos p
    JOIN deleted d ON d.id_prestamo = p.id_prestamo;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Prestamos_Auditoria ON dbo.Prestamos
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.syn_Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Prestamos',
           CASE WHEN i.id_prestamo IS NOT NULL AND d.id_prestamo IS NOT NULL THEN 'UPDATE'
                WHEN i.id_prestamo IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_prestamo, d.id_prestamo),
           (SELECT x.* FROM deleted  x WHERE x.id_prestamo = d.id_prestamo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_prestamo = i.id_prestamo FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_prestamo = i.id_prestamo;
END;
GO

/* =====================================================================
   PAGOS
   ===================================================================== */

/* Cada pago descuenta el saldo pendiente del prestamo. Si llega a 0 el
   prestamo pasa a PAGADO. Si se anula (DELETE) un pago, el saldo se
   restituye y un prestamo PAGADO vuelve a ACTIVO. */
CREATE OR ALTER TRIGGER dbo.tr_Pagos_ActualizarPrestamo ON dbo.Pagos
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;
    DECLARE @msg NVARCHAR(400);

    -- 1. Pagos nuevos o modificados solo para prestamos vigentes
    IF EXISTS (SELECT 1
               FROM inserted i
               LEFT JOIN deleted d    ON d.id_pago     = i.id_pago
               JOIN dbo.Prestamos p   ON p.id_prestamo = i.id_prestamo
               WHERE p.estado NOT IN ('ACTIVO','MORA')
                 AND (d.id_pago IS NULL OR d.id_prestamo <> i.id_prestamo OR d.monto <> i.monto))
        THROW 50501, N'Solo se pueden registrar pagos a préstamos ACTIVOS o en MORA.', 1;

    -- 2. La fecha del pago no puede ser anterior al desembolso
    IF EXISTS (SELECT 1 FROM inserted i JOIN dbo.Prestamos p ON p.id_prestamo = i.id_prestamo
               WHERE i.fecha < p.fecha_desembolso)
        THROW 50502, N'La fecha del pago no puede ser anterior a la fecha de desembolso del préstamo.', 1;

    -- 3. Efecto neto por prestamo
    DECLARE @efecto TABLE (id_prestamo INT PRIMARY KEY, pagado DECIMAL(18,2) NOT NULL);

    INSERT INTO @efecto (id_prestamo, pagado)
    SELECT x.id_prestamo, SUM(x.monto)
    FROM (SELECT id_prestamo, monto FROM inserted
          UNION ALL
          SELECT id_prestamo, -monto FROM deleted) x
    GROUP BY x.id_prestamo;

    -- 4. No se puede pagar mas de lo que se debe
    IF EXISTS (SELECT 1 FROM dbo.Prestamos p JOIN @efecto e ON e.id_prestamo = p.id_prestamo
               WHERE p.saldo_pendiente - e.pagado < 0)
    BEGIN
        SELECT TOP (1) @msg = CONCAT(N'El pago excede la deuda del préstamo ', p.id_prestamo,
                                     N'. Saldo pendiente: $', FORMAT(p.saldo_pendiente, 'N2'), N'.')
        FROM dbo.Prestamos p JOIN @efecto e ON e.id_prestamo = p.id_prestamo
        WHERE p.saldo_pendiente - e.pagado < 0;
        THROW 50503, @msg, 1;
    END;

    -- 5. Actualizar saldo y estado del prestamo
    UPDATE p
       SET p.saldo_pendiente = p.saldo_pendiente - e.pagado,
           p.estado = CASE WHEN p.saldo_pendiente - e.pagado = 0 THEN 'PAGADO'
                           WHEN p.estado = 'PAGADO'               THEN 'ACTIVO'
                           ELSE p.estado END
    FROM dbo.Prestamos p
    JOIN @efecto e ON e.id_prestamo = p.id_prestamo
    WHERE e.pagado <> 0;
END;
GO

CREATE OR ALTER TRIGGER dbo.tr_Pagos_Auditoria ON dbo.Pagos
AFTER INSERT, UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF NOT EXISTS (SELECT 1 FROM inserted) AND NOT EXISTS (SELECT 1 FROM deleted) RETURN;

    INSERT INTO dbo.syn_Auditoria (base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos)
    SELECT DB_NAME(), N'Pagos',
           CASE WHEN i.id_pago IS NOT NULL AND d.id_pago IS NOT NULL THEN 'UPDATE'
                WHEN i.id_pago IS NOT NULL THEN 'INSERT' ELSE 'DELETE' END,
           COALESCE(i.id_pago, d.id_pago),
           (SELECT x.* FROM deleted  x WHERE x.id_pago = d.id_pago FOR JSON PATH, WITHOUT_ARRAY_WRAPPER),
           (SELECT x.* FROM inserted x WHERE x.id_pago = i.id_pago FOR JSON PATH, WITHOUT_ARRAY_WRAPPER)
    FROM inserted i
    FULL OUTER JOIN deleted d ON d.id_pago = i.id_pago;
END;
GO

PRINT N'>> Triggers creados correctamente.';
GO


-- #####################################################################
-- ARCHIVO: 06_Procedimientos.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 06 : PROCEDIMIENTOS ALMACENADOS (BancoCentral)
     A. CRUD Clientes       (4)
     B. CRUD Cuentas        (4)   -> Insertar/Consultar/Actualizar usan el Linked Server
     C. CRUD Transacciones  (4)   -> valida saldo negativo y transferencias sin fondos
     D. CRUD Prestamos      (4)   -> Insertar/Consultar usan el Linked Server
     E. CRUD Pagos          (4)
     F. Consulta 5: transacciones de un cliente en un rango de fechas
     G. Procedimientos DISTRIBUIDOS (sp_Dist_*)
   (El CRUD de TiposCuenta, Sucursales y Empleados esta en cada nodo de
    sucursal, script 01, y se invoca desde aqui por RPC, p. ej.:
    SRV_BOGOTA.BancoBogota.dbo.sp_Empleado_Insertar)
   Requisito: 03 (Linked Servers). Las vistas vw_Dist_* se crean en el
   script 07; aqui se aprovecha la resolucion diferida de nombres.
   Todos usan TRY...CATCH. Los errores de negocio se lanzan con THROW
   (codigos 50000-50999) y se re-lanzan en el CATCH para que el
   llamador los reciba.
   ===================================================================== */
USE BancoCentral;
GO

/* =====================================================================
   A. CLIENTES
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.sp_Cliente_Insertar
    @nombre       NVARCHAR(100),
    @documento    VARCHAR(20),
    @direccion    NVARCHAR(150) = NULL,
    @telefono     VARCHAR(20)   = NULL,
    @tipo_cliente VARCHAR(10)   = 'NATURAL',
    @id_cliente   INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 50001, N'El nombre del cliente es obligatorio.', 1;
        IF LTRIM(RTRIM(ISNULL(@documento, ''))) = ''
            THROW 50002, N'El documento del cliente es obligatorio.', 1;
        IF @tipo_cliente NOT IN ('NATURAL','JURIDICO')
            THROW 50003, N'Tipo de cliente no válido (NATURAL o JURIDICO).', 1;
        IF EXISTS (SELECT 1 FROM dbo.Clientes WHERE documento = @documento)
            THROW 50004, N'Ya existe un cliente registrado con ese documento.', 1;

        INSERT INTO dbo.Clientes (nombre, documento, direccion, telefono, tipo_cliente)
        VALUES (@nombre, @documento, @direccion, @telefono, @tipo_cliente);

        SET @id_cliente = SCOPE_IDENTITY();
        SELECT N'Cliente registrado correctamente' AS mensaje, @id_cliente AS id_cliente;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Cliente_Consultar
    @id_cliente INT         = NULL,
    @documento  VARCHAR(20) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT c.id_cliente, c.nombre, c.documento, c.direccion, c.telefono,
               c.tipo_cliente, c.estado, c.fecha_registro,
               dbo.fn_SaldoTotalCliente(c.id_cliente) AS saldo_total
        FROM dbo.Clientes c
        WHERE (@id_cliente IS NULL OR c.id_cliente = @id_cliente)
          AND (@documento  IS NULL OR c.documento  = @documento)
        ORDER BY c.id_cliente;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Cliente_Actualizar
    @id_cliente   INT,
    @nombre       NVARCHAR(100) = NULL,
    @direccion    NVARCHAR(150) = NULL,
    @telefono     VARCHAR(20)   = NULL,
    @tipo_cliente VARCHAR(10)   = NULL,
    @estado       VARCHAR(10)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE id_cliente = @id_cliente)
            THROW 50005, N'El cliente no existe.', 1;
        IF @tipo_cliente IS NOT NULL AND @tipo_cliente NOT IN ('NATURAL','JURIDICO')
            THROW 50003, N'Tipo de cliente no válido (NATURAL o JURIDICO).', 1;
        IF @estado IS NOT NULL AND @estado NOT IN ('ACTIVO','INACTIVO')
            THROW 50006, N'Estado no válido (ACTIVO o INACTIVO).', 1;

        UPDATE dbo.Clientes
           SET nombre       = COALESCE(@nombre, nombre),
               direccion    = COALESCE(@direccion, direccion),
               telefono     = COALESCE(@telefono, telefono),
               tipo_cliente = COALESCE(@tipo_cliente, tipo_cliente),
               estado       = COALESCE(@estado, estado)
         WHERE id_cliente = @id_cliente;   -- tr_Clientes_ValidarInactivacion valida el cambio de estado

        SELECT N'Cliente actualizado correctamente' AS mensaje, @id_cliente AS id_cliente;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Cliente_Eliminar
    @id_cliente INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE id_cliente = @id_cliente)
            THROW 50005, N'El cliente no existe.', 1;

        DELETE FROM dbo.Clientes WHERE id_cliente = @id_cliente;   -- tr_Clientes_ControlEliminacion decide logico/fisico

        IF EXISTS (SELECT 1 FROM dbo.Clientes WHERE id_cliente = @id_cliente)
            SELECT N'El cliente tiene historial: se realizó borrado lógico (INACTIVO)' AS mensaje, @id_cliente AS id_cliente;
        ELSE
            SELECT N'Cliente eliminado físicamente' AS mensaje, @id_cliente AS id_cliente;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   B. CUENTAS
   ===================================================================== */

/* Acceso DISTRIBUIDO: valida el tipo de cuenta en SRV_MEDELLIN (copia maestra
   del catalogo) y la sucursal en los 5 nodos (vw_Dist_Sucursales) antes de
   abrir la transaccion local. */
CREATE OR ALTER PROCEDURE dbo.sp_Cuenta_Insertar
    @numero_cuenta  VARCHAR(20),
    @id_cliente     INT,
    @id_tipo_cuenta INT,
    @id_sucursal    INT,
    @saldo_inicial  DECIMAL(18,2) = 0,
    @id_cuenta      INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@numero_cuenta, ''))) = ''
            THROW 50011, N'El número de cuenta es obligatorio.', 1;
        IF ISNULL(@saldo_inicial, 0) < 0
            THROW 50012, N'El saldo inicial no puede ser negativo.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Cuentas WHERE numero_cuenta = @numero_cuenta)
            THROW 50013, N'Ya existe una cuenta con ese número.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE id_cliente = @id_cliente AND estado = 'ACTIVO')
            THROW 50014, N'El cliente no existe o está INACTIVO.', 1;

        -- Validacion distribuida (Linked Server)
        IF NOT EXISTS (SELECT 1 FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 50015, N'El tipo de cuenta no existe en el servidor remoto.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.vw_Dist_Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 50016, N'La sucursal no existe en el servidor remoto.', 1;

        BEGIN TRANSACTION;
            INSERT INTO dbo.Cuentas (numero_cuenta, id_cliente, id_tipo_cuenta, id_sucursal, saldo, estado)
            VALUES (@numero_cuenta, @id_cliente, @id_tipo_cuenta, @id_sucursal, 0, 'ACTIVA');

            SET @id_cuenta = SCOPE_IDENTITY();

            -- El saldo inicial entra como deposito de apertura (el trigger actualiza el saldo)
            IF ISNULL(@saldo_inicial, 0) > 0
                INSERT INTO dbo.Transacciones (id_cuenta, tipo, monto, descripcion)
                VALUES (@id_cuenta, 'DEPOSITO', @saldo_inicial, N'Depósito de apertura');
        COMMIT TRANSACTION;

        SELECT N'Cuenta creada correctamente' AS mensaje, @id_cuenta AS id_cuenta,
               @numero_cuenta AS numero_cuenta, saldo
        FROM dbo.Cuentas WHERE id_cuenta = @id_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Acceso DISTRIBUIDO: une las cuentas locales con tipos y sucursales remotos */
CREATE OR ALTER PROCEDURE dbo.sp_Cuenta_Consultar
    @id_cuenta  INT = NULL,
    @id_cliente INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT cu.id_cuenta, cu.numero_cuenta,
               cl.id_cliente, cl.nombre AS cliente,
               tc.nombre AS tipo_cuenta,
               s.nombre  AS sucursal, s.ciudad,
               cu.saldo, cu.estado, cu.fecha_apertura
        FROM dbo.Cuentas cu
        JOIN dbo.Clientes cl ON cl.id_cliente = cu.id_cliente
        LEFT JOIN SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta tc ON tc.id_tipo_cuenta = cu.id_tipo_cuenta
        LEFT JOIN dbo.vw_Dist_Sucursales  s  ON s.id_sucursal     = cu.id_sucursal
        WHERE (@id_cuenta  IS NULL OR cu.id_cuenta  = @id_cuenta)
          AND (@id_cliente IS NULL OR cu.id_cliente = @id_cliente)
        ORDER BY cu.id_cuenta;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* El saldo NO se actualiza aqui: solo cambia por transacciones. */
CREATE OR ALTER PROCEDURE dbo.sp_Cuenta_Actualizar
    @id_cuenta      INT,
    @id_tipo_cuenta INT         = NULL,
    @id_sucursal    INT         = NULL,
    @estado         VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @saldo DECIMAL(18,2);
        SELECT @saldo = saldo FROM dbo.Cuentas WHERE id_cuenta = @id_cuenta;

        IF @saldo IS NULL
            THROW 50017, N'La cuenta no existe.', 1;
        IF @estado IS NOT NULL AND @estado NOT IN ('ACTIVA','INACTIVA','BLOQUEADA','CERRADA')
            THROW 50018, N'Estado no válido (ACTIVA, INACTIVA, BLOQUEADA, CERRADA).', 1;
        IF @estado = 'CERRADA' AND @saldo > 0
            THROW 50019, N'No se puede cerrar una cuenta con saldo.', 1;
        IF @id_tipo_cuenta IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 50015, N'El tipo de cuenta no existe en el servidor remoto.', 1;
        IF @id_sucursal IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM dbo.vw_Dist_Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 50016, N'La sucursal no existe en el servidor remoto.', 1;

        UPDATE dbo.Cuentas
           SET id_tipo_cuenta = COALESCE(@id_tipo_cuenta, id_tipo_cuenta),
               id_sucursal    = COALESCE(@id_sucursal, id_sucursal),
               estado         = COALESCE(@estado, estado)
         WHERE id_cuenta = @id_cuenta;

        SELECT N'Cuenta actualizada correctamente' AS mensaje, @id_cuenta AS id_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Cuenta_Eliminar
    @id_cuenta INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Cuentas WHERE id_cuenta = @id_cuenta)
            THROW 50017, N'La cuenta no existe.', 1;

        DELETE FROM dbo.Cuentas WHERE id_cuenta = @id_cuenta;   -- tr_Cuentas_EvitarEliminacionConSaldo

        IF EXISTS (SELECT 1 FROM dbo.Cuentas WHERE id_cuenta = @id_cuenta)
            SELECT N'La cuenta tiene movimientos: se CERRÓ (borrado lógico)' AS mensaje, @id_cuenta AS id_cuenta;
        ELSE
            SELECT N'Cuenta eliminada físicamente' AS mensaje, @id_cuenta AS id_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   C. TRANSACCIONES
   ===================================================================== */

/* Registra DEPOSITO, RETIRO o TRANSFERENCIA.
   Validaciones obligatorias:
     - No permitir saldo negativo (retiro mayor al saldo).
     - No permitir transferencias sin fondos.
   El saldo lo actualiza el trigger tr_Transacciones_ActualizarSaldo. */
CREATE OR ALTER PROCEDURE dbo.sp_Transaccion_Insertar
    @id_cuenta         INT,
    @tipo              VARCHAR(15),
    @monto             DECIMAL(18,2),
    @id_cuenta_destino INT           = NULL,
    @descripcion       NVARCHAR(200) = NULL,
    @id_transaccion    INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    BEGIN TRY
        DECLARE @saldo DECIMAL(18,2), @estado VARCHAR(10), @estado_destino VARCHAR(10);
        DECLARE @msg NVARCHAR(400);

        IF @tipo NOT IN ('DEPOSITO','RETIRO','TRANSFERENCIA')
            THROW 50021, N'Tipo de transacción no válido (DEPOSITO, RETIRO, TRANSFERENCIA).', 1;
        IF ISNULL(@monto, 0) <= 0
            THROW 50022, N'El monto debe ser mayor que cero.', 1;
        IF @tipo = 'TRANSFERENCIA' AND @id_cuenta_destino IS NULL
            THROW 50023, N'Una transferencia requiere cuenta destino.', 1;
        IF @tipo = 'TRANSFERENCIA' AND @id_cuenta_destino = @id_cuenta
            THROW 50024, N'La cuenta destino debe ser diferente a la cuenta origen.', 1;
        IF @tipo <> 'TRANSFERENCIA'
            SET @id_cuenta_destino = NULL;

        BEGIN TRANSACTION;
            -- Bloqueo de la cuenta origen para evitar condiciones de carrera
            SELECT @saldo = saldo, @estado = estado
            FROM dbo.Cuentas WITH (UPDLOCK, ROWLOCK)
            WHERE id_cuenta = @id_cuenta;

            IF @estado IS NULL
                THROW 50025, N'La cuenta origen no existe.', 1;
            IF @estado <> 'ACTIVA'
                THROW 50026, N'La cuenta origen no está ACTIVA.', 1;

            IF @tipo = 'TRANSFERENCIA'
            BEGIN
                SELECT @estado_destino = estado
                FROM dbo.Cuentas WITH (UPDLOCK, ROWLOCK)
                WHERE id_cuenta = @id_cuenta_destino;

                IF @estado_destino IS NULL
                    THROW 50027, N'La cuenta destino no existe.', 1;
                IF @estado_destino <> 'ACTIVA'
                    THROW 50028, N'La cuenta destino no está ACTIVA.', 1;
                -- VALIDACION: no permitir transferencias sin fondos
                IF @saldo < @monto
                BEGIN
                    SET @msg = CONCAT(N'Transferencia rechazada: fondos insuficientes. Saldo disponible: $',
                                      FORMAT(@saldo, 'N2'), N', monto solicitado: $', FORMAT(@monto, 'N2'), N'.');
                    THROW 50029, @msg, 1;
                END;
            END;

            -- VALIDACION: no permitir saldo negativo
            IF @tipo = 'RETIRO' AND @saldo - @monto < 0
            BEGIN
                SET @msg = CONCAT(N'Retiro rechazado: el saldo quedaría negativo. Saldo disponible: $',
                                  FORMAT(@saldo, 'N2'), N', monto solicitado: $', FORMAT(@monto, 'N2'), N'.');
                THROW 50030, @msg, 1;
            END;

            INSERT INTO dbo.Transacciones (id_cuenta, tipo, monto, id_cuenta_destino, descripcion)
            VALUES (@id_cuenta, @tipo, @monto, @id_cuenta_destino, @descripcion);

            SET @id_transaccion = SCOPE_IDENTITY();
        COMMIT TRANSACTION;

        SELECT N'Transacción registrada correctamente' AS mensaje,
               @id_transaccion AS id_transaccion, @tipo AS tipo, @monto AS monto,
               (SELECT saldo FROM dbo.Cuentas WHERE id_cuenta = @id_cuenta)         AS nuevo_saldo_origen,
               (SELECT saldo FROM dbo.Cuentas WHERE id_cuenta = @id_cuenta_destino) AS nuevo_saldo_destino;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Transaccion_Consultar
    @id_transaccion INT = NULL,
    @id_cuenta      INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT t.id_transaccion, t.fecha, t.tipo, t.monto,
               co.numero_cuenta AS cuenta_origen,
               cd.numero_cuenta AS cuenta_destino,
               t.descripcion
        FROM dbo.Transacciones t
        JOIN dbo.Cuentas co      ON co.id_cuenta = t.id_cuenta
        LEFT JOIN dbo.Cuentas cd ON cd.id_cuenta = t.id_cuenta_destino
        WHERE (@id_transaccion IS NULL OR t.id_transaccion = @id_transaccion)
          AND (@id_cuenta IS NULL OR t.id_cuenta = @id_cuenta OR t.id_cuenta_destino = @id_cuenta)
        ORDER BY t.fecha, t.id_transaccion;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* Solo se puede corregir la descripcion (los datos financieros son inmutables). */
CREATE OR ALTER PROCEDURE dbo.sp_Transaccion_Actualizar
    @id_transaccion INT,
    @descripcion    NVARCHAR(200)
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Transacciones WHERE id_transaccion = @id_transaccion)
            THROW 50031, N'La transacción no existe.', 1;

        UPDATE dbo.Transacciones SET descripcion = @descripcion WHERE id_transaccion = @id_transaccion;
        SELECT N'Descripción de la transacción actualizada' AS mensaje, @id_transaccion AS id_transaccion;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Eliminar = ANULAR la transaccion: el trigger revierte el efecto en los saldos
   (falla si al revertir algun saldo quedaria negativo). */
CREATE OR ALTER PROCEDURE dbo.sp_Transaccion_Eliminar
    @id_transaccion INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Transacciones WHERE id_transaccion = @id_transaccion)
            THROW 50031, N'La transacción no existe.', 1;

        DELETE FROM dbo.Transacciones WHERE id_transaccion = @id_transaccion;
        SELECT N'Transacción anulada y saldos revertidos' AS mensaje, @id_transaccion AS id_transaccion;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   D. PRESTAMOS
   ===================================================================== */

/* Acceso DISTRIBUIDO: si no se envia la tasa, se toma del producto
   financiero almacenado en el servidor remoto. */
CREATE OR ALTER PROCEDURE dbo.sp_Prestamo_Insertar
    @id_cliente  INT,
    @monto       DECIMAL(18,2),
    @plazo       INT,
    @interes     DECIMAL(5,2) = NULL,
    @id_producto INT          = NULL,
    @id_prestamo INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE id_cliente = @id_cliente AND estado = 'ACTIVO')
            THROW 50041, N'El cliente no existe o está INACTIVO.', 1;
        IF ISNULL(@monto, 0) <= 0
            THROW 50042, N'El monto del préstamo debe ser mayor que cero.', 1;
        IF @plazo IS NULL OR @plazo NOT BETWEEN 1 AND 360
            THROW 50043, N'El plazo debe estar entre 1 y 360 meses.', 1;

        IF @id_producto IS NOT NULL
        BEGIN
            DECLARE @tasa_producto DECIMAL(5,2);
            SELECT @tasa_producto = tasa_interes
            FROM SRV_MEDELLIN.BancoMedellin.dbo.ProductosFinancieros
            WHERE id_producto = @id_producto AND categoria = 'CREDITO' AND activo = 1;

            IF @tasa_producto IS NULL
                THROW 50044, N'El producto no existe en el servidor remoto o no es un crédito activo.', 1;
            SET @interes = COALESCE(@interes, @tasa_producto);
        END;

        IF @interes IS NULL OR @interes NOT BETWEEN 0 AND 100
            THROW 50045, N'Debe indicar una tasa de interés válida (0 - 100 %) o un producto de crédito.', 1;

        INSERT INTO dbo.Prestamos (id_cliente, id_producto, monto, interes, plazo, estado)
        VALUES (@id_cliente, @id_producto, @monto, @interes, @plazo, 'ACTIVO');   -- el trigger calcula saldo_pendiente

        SET @id_prestamo = SCOPE_IDENTITY();

        SELECT N'Préstamo registrado correctamente' AS mensaje, id_prestamo, monto, interes, plazo,
               saldo_pendiente AS total_a_pagar, estado
        FROM dbo.Prestamos WHERE id_prestamo = @id_prestamo;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Acceso DISTRIBUIDO: muestra el nombre del producto desde el servidor remoto */
CREATE OR ALTER PROCEDURE dbo.sp_Prestamo_Consultar
    @id_prestamo INT = NULL,
    @id_cliente  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT p.id_prestamo, c.id_cliente, c.nombre AS cliente,
               pf.nombre AS producto,
               p.monto, p.interes, p.plazo,
               dbo.fn_CalcularTotalPrestamo(p.monto, p.interes, p.plazo) AS total_a_pagar,
               p.saldo_pendiente, p.estado, p.fecha_desembolso
        FROM dbo.Prestamos p
        JOIN dbo.Clientes c ON c.id_cliente = p.id_cliente
        LEFT JOIN SRV_MEDELLIN.BancoMedellin.dbo.ProductosFinancieros pf ON pf.id_producto = p.id_producto
        WHERE (@id_prestamo IS NULL OR p.id_prestamo = @id_prestamo)
          AND (@id_cliente  IS NULL OR p.id_cliente  = @id_cliente)
        ORDER BY p.id_prestamo;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Prestamo_Actualizar
    @id_prestamo INT,
    @monto       DECIMAL(18,2) = NULL,
    @interes     DECIMAL(5,2)  = NULL,
    @plazo       INT           = NULL,
    @estado      VARCHAR(10)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Prestamos WHERE id_prestamo = @id_prestamo)
            THROW 50046, N'El préstamo no existe.', 1;
        IF @estado IS NOT NULL AND @estado NOT IN ('ACTIVO','MORA','PAGADO','CANCELADO')
            THROW 50047, N'Estado no válido (ACTIVO, MORA, PAGADO, CANCELADO).', 1;
        IF @monto IS NOT NULL AND @monto <= 0
            THROW 50042, N'El monto del préstamo debe ser mayor que cero.', 1;

        UPDATE dbo.Prestamos
           SET monto   = COALESCE(@monto, monto),
               interes = COALESCE(@interes, interes),
               plazo   = COALESCE(@plazo, plazo),
               estado  = COALESCE(@estado, estado)
         WHERE id_prestamo = @id_prestamo;   -- tr_Prestamos_Integridad valida y reliquida

        SELECT N'Préstamo actualizado correctamente' AS mensaje, id_prestamo, monto, interes, plazo, saldo_pendiente, estado
        FROM dbo.Prestamos WHERE id_prestamo = @id_prestamo;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Prestamo_Eliminar
    @id_prestamo INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Prestamos WHERE id_prestamo = @id_prestamo)
            THROW 50046, N'El préstamo no existe.', 1;

        DELETE FROM dbo.Prestamos WHERE id_prestamo = @id_prestamo;   -- tr_Prestamos_ControlEliminacion
        SELECT N'Préstamo eliminado correctamente' AS mensaje, @id_prestamo AS id_prestamo;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   E. PAGOS
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.sp_Pago_Insertar
    @id_prestamo INT,
    @monto       DECIMAL(18,2),
    @fecha       DATETIME2(0) = NULL,
    @id_pago     INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @saldo DECIMAL(18,2), @estado VARCHAR(10), @msg NVARCHAR(400);

        SELECT @saldo = saldo_pendiente, @estado = estado
        FROM dbo.Prestamos WHERE id_prestamo = @id_prestamo;

        IF @estado IS NULL
            THROW 50051, N'El préstamo no existe.', 1;
        IF @estado NOT IN ('ACTIVO','MORA')
            THROW 50052, N'Solo se pueden registrar pagos a préstamos ACTIVOS o en MORA.', 1;
        IF ISNULL(@monto, 0) <= 0
            THROW 50053, N'El monto del pago debe ser mayor que cero.', 1;
        IF @monto > @saldo
        BEGIN
            SET @msg = CONCAT(N'El pago ($', FORMAT(@monto, 'N2'), N') excede el saldo pendiente ($', FORMAT(@saldo, 'N2'), N').');
            THROW 50054, @msg, 1;
        END;

        INSERT INTO dbo.Pagos (id_prestamo, monto, fecha)
        VALUES (@id_prestamo, @monto, COALESCE(@fecha, SYSDATETIME()));   -- el trigger descuenta el saldo

        SET @id_pago = SCOPE_IDENTITY();

        SELECT N'Pago registrado correctamente' AS mensaje, @id_pago AS id_pago,
               p.saldo_pendiente AS nuevo_saldo_prestamo, p.estado AS estado_prestamo
        FROM dbo.Prestamos p WHERE p.id_prestamo = @id_prestamo;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Pago_Consultar
    @id_pago     INT = NULL,
    @id_prestamo INT = NULL,
    @id_cliente  INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT g.id_pago, g.fecha, g.monto,
               p.id_prestamo, p.estado AS estado_prestamo, p.saldo_pendiente,
               c.id_cliente, c.nombre AS cliente
        FROM dbo.Pagos g
        JOIN dbo.Prestamos p ON p.id_prestamo = g.id_prestamo
        JOIN dbo.Clientes  c ON c.id_cliente  = p.id_cliente
        WHERE (@id_pago     IS NULL OR g.id_pago     = @id_pago)
          AND (@id_prestamo IS NULL OR g.id_prestamo = @id_prestamo)
          AND (@id_cliente  IS NULL OR c.id_cliente  = @id_cliente)
        ORDER BY g.fecha, g.id_pago;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Pago_Actualizar
    @id_pago INT,
    @monto   DECIMAL(18,2) = NULL,
    @fecha   DATETIME2(0)  = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Pagos WHERE id_pago = @id_pago)
            THROW 50055, N'El pago no existe.', 1;
        IF @monto IS NOT NULL AND @monto <= 0
            THROW 50053, N'El monto del pago debe ser mayor que cero.', 1;

        UPDATE dbo.Pagos
           SET monto = COALESCE(@monto, monto),
               fecha = COALESCE(@fecha, fecha)
         WHERE id_pago = @id_pago;   -- el trigger ajusta la diferencia en el prestamo

        SELECT N'Pago actualizado correctamente' AS mensaje, @id_pago AS id_pago;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Pago_Eliminar
    @id_pago INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Pagos WHERE id_pago = @id_pago)
            THROW 50055, N'El pago no existe.', 1;

        DELETE FROM dbo.Pagos WHERE id_pago = @id_pago;   -- el trigger restituye el saldo del prestamo
        SELECT N'Pago anulado; saldo del préstamo restituido' AS mensaje, @id_pago AS id_pago;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   F. CONSULTA 5: Transacciones de un cliente en un rango de fechas
   ===================================================================== */
CREATE OR ALTER PROCEDURE dbo.sp_TransaccionesClienteRangoFechas
    @id_cliente   INT,
    @fecha_inicio DATE,
    @fecha_fin    DATE
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Clientes WHERE id_cliente = @id_cliente)
            THROW 50061, N'El cliente no existe.', 1;
        IF @fecha_inicio IS NULL OR @fecha_fin IS NULL OR @fecha_inicio > @fecha_fin
            THROW 50062, N'Rango de fechas no válido: la fecha inicial debe ser menor o igual a la final.', 1;

        SELECT t.id_transaccion, t.fecha, t.tipo,
               co.numero_cuenta AS cuenta_origen,
               cd.numero_cuenta AS cuenta_destino,
               CASE WHEN t.tipo = 'DEPOSITO' THEN N'ENTRADA'
                    WHEN t.tipo = 'RETIRO'   THEN N'SALIDA'
                    WHEN co.id_cliente = @id_cliente AND cd.id_cliente = @id_cliente THEN N'ENTRE CUENTAS PROPIAS'
                    WHEN co.id_cliente = @id_cliente THEN N'SALIDA'
                    ELSE N'ENTRADA' END AS sentido,
               t.monto, t.descripcion
        FROM dbo.Transacciones t
        JOIN dbo.Cuentas co      ON co.id_cuenta = t.id_cuenta
        LEFT JOIN dbo.Cuentas cd ON cd.id_cuenta = t.id_cuenta_destino
        WHERE (co.id_cliente = @id_cliente OR cd.id_cliente = @id_cliente)
          AND t.fecha >= @fecha_inicio
          AND t.fecha <  DATEADD(DAY, 1, @fecha_fin)
        ORDER BY t.fecha, t.id_transaccion;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* =====================================================================
   G. PROCEDIMIENTOS DISTRIBUIDOS (consultan datos entre servidores)
   ===================================================================== */

/* G.1 Cantidad de cuentas y saldo por sucursal (Consulta 4).
       Parte de las sucursales REMOTAS para mostrar tambien las que no tienen cuentas. */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_CuentasPorSucursal
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre AS sucursal, s.ciudad,
               COUNT(cu.id_cuenta)                                         AS cantidad_cuentas,
               SUM(CASE WHEN cu.estado = 'ACTIVA' THEN 1 ELSE 0 END)       AS cuentas_activas,
               CAST(ISNULL(SUM(cu.saldo), 0) AS DECIMAL(18,2))             AS saldo_total
        FROM dbo.vw_Dist_Sucursales s
        LEFT JOIN dbo.Cuentas cu ON cu.id_sucursal = s.id_sucursal
        GROUP BY s.id_sucursal, s.nombre, s.ciudad
        ORDER BY cantidad_cuentas DESC, s.id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* G.2 Clientes + sucursal + tipo de cuenta (Consulta 12) usando OPENQUERY:
       la consulta de catalogos se ejecuta completa en el servidor remoto. */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_ClientesSucursalTipoCuenta
    @ciudad NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT cl.id_cliente, cl.nombre AS cliente, cl.documento, cl.tipo_cliente,
               cu.numero_cuenta, r.tipo_cuenta, r.sucursal, r.ciudad,
               cu.saldo, cu.estado AS estado_cuenta
        FROM dbo.Clientes cl
        JOIN dbo.Cuentas  cu ON cu.id_cliente = cl.id_cliente
        -- Cada OPENQUERY se ejecuta en el nodo de su ciudad: solo viaja el resultado
        JOIN (
              SELECT * FROM OPENQUERY(SRV_MEDELLIN,  'SELECT s.id_sucursal, s.nombre AS sucursal, s.ciudad, t.id_tipo_cuenta, t.nombre AS tipo_cuenta FROM BancoMedellin.dbo.Sucursales s CROSS JOIN BancoMedellin.dbo.TiposCuenta t')
              UNION ALL
              SELECT * FROM OPENQUERY(SRV_BOGOTA,    'SELECT s.id_sucursal, s.nombre AS sucursal, s.ciudad, t.id_tipo_cuenta, t.nombre AS tipo_cuenta FROM BancoBogota.dbo.Sucursales s CROSS JOIN BancoBogota.dbo.TiposCuenta t')
              UNION ALL
              SELECT * FROM OPENQUERY(SRV_CARTAGENA, 'SELECT s.id_sucursal, s.nombre AS sucursal, s.ciudad, t.id_tipo_cuenta, t.nombre AS tipo_cuenta FROM BancoCartagena.dbo.Sucursales s CROSS JOIN BancoCartagena.dbo.TiposCuenta t')
              UNION ALL
              SELECT * FROM OPENQUERY(SRV_SANANDRES, 'SELECT s.id_sucursal, s.nombre AS sucursal, s.ciudad, t.id_tipo_cuenta, t.nombre AS tipo_cuenta FROM BancoSanAndres.dbo.Sucursales s CROSS JOIN BancoSanAndres.dbo.TiposCuenta t')
              UNION ALL
              SELECT * FROM OPENQUERY(SRV_CALI,      'SELECT s.id_sucursal, s.nombre AS sucursal, s.ciudad, t.id_tipo_cuenta, t.nombre AS tipo_cuenta FROM BancoCali.dbo.Sucursales s CROSS JOIN BancoCali.dbo.TiposCuenta t')
             ) r
             ON r.id_sucursal = cu.id_sucursal AND r.id_tipo_cuenta = cu.id_tipo_cuenta
        WHERE @ciudad IS NULL OR r.ciudad = @ciudad
        ORDER BY r.ciudad, cl.nombre;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* G.3 Tablero de la sede central: indicadores de cada sede
       (empleados remotos + clientes, cuentas, saldos y cartera locales). */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_ResumenSedes
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre AS sede, s.ciudad,
               CASE WHEN s.es_sede_central = 1 THEN N'CENTRAL' ELSE N'SUCURSAL' END AS tipo_sede,
               ISNULL(e.empleados, 0)                    AS empleados_activos,
               ISNULL(c.clientes, 0)                     AS clientes,
               ISNULL(c.cuentas, 0)                      AS cuentas,
               CAST(ISNULL(c.saldo, 0) AS DECIMAL(18,2)) AS saldo_captado
        FROM dbo.vw_Dist_Sucursales s
        LEFT JOIN (SELECT id_sucursal, COUNT(*) AS empleados
                   FROM dbo.vw_Dist_Empleados
                   WHERE activo = 1
                   GROUP BY id_sucursal) e ON e.id_sucursal = s.id_sucursal
        LEFT JOIN (SELECT id_sucursal, COUNT(DISTINCT id_cliente) AS clientes, COUNT(*) AS cuentas, SUM(saldo) AS saldo
                   FROM dbo.Cuentas
                   WHERE estado <> 'CERRADA'
                   GROUP BY id_sucursal) c ON c.id_sucursal = s.id_sucursal
        ORDER BY s.es_sede_central DESC, s.id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* G.4 Registrar un empleado: la sede central ENRUTA la operacion al nodo
       de la ciudad de la sucursal y ejecuta alli el procedimiento REMOTO (RPC).
       El nombre del procedimiento remoto se arma con el directorio dbo.Nodos:
       EXEC SRV_<CIUDAD>.Banco<Ciudad>.dbo.sp_Empleado_Insertar ... */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_RegistrarEmpleado
    @nombre      NVARCHAR(100),
    @documento   VARCHAR(20),
    @cargo       NVARCHAR(50),
    @id_sucursal INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        DECLARE @srv SYSNAME, @bd SYSNAME, @proc NVARCHAR(400);

        SELECT @srv = n.linked_server, @bd = n.base_datos
        FROM dbo.vw_Dist_Sucursales s
        JOIN dbo.Nodos n ON n.id_nodo = s.id_nodo
        WHERE s.id_sucursal = @id_sucursal;

        IF @srv IS NULL
            THROW 50071, N'La sucursal no existe en ninguno de los nodos.', 1;
        IF EXISTS (SELECT 1 FROM dbo.vw_Dist_Empleados WHERE documento = @documento)
            THROW 50072, N'Ya existe un empleado con ese documento en alguna de las sedes.', 1;

        SET @proc = QUOTENAME(@srv) + N'.' + QUOTENAME(@bd) + N'.dbo.sp_Empleado_Insertar';
        EXEC @proc @nombre = @nombre, @documento = @documento, @cargo = @cargo, @id_sucursal = @id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* G.5 Consultar el historial de auditoria de TODOS los nodos (vw_Dist_Auditoria) */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_ConsultarAuditoria
    @tabla  SYSNAME      = NULL,
    @ciudad NVARCHAR(50) = NULL,
    @desde  DATE         = NULL,
    @hasta  DATE         = NULL,
    @top    INT          = 100
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT TOP (@top) a.nodo, a.id_auditoria, a.fecha, a.base_datos, a.tabla, a.operacion,
               a.id_registro, a.usuario, a.datos_anteriores, a.datos_nuevos
        FROM dbo.vw_Dist_Auditoria a
        WHERE (@tabla  IS NULL OR a.tabla = @tabla)
          AND (@ciudad IS NULL OR a.nodo  = @ciudad)
          AND (@desde  IS NULL OR a.fecha >= @desde)
          AND (@hasta  IS NULL OR a.fecha <  DATEADD(DAY, 1, @hasta))
        ORDER BY a.fecha DESC, a.id_auditoria DESC;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* G.6 Gestion de un catalogo REPLICADO desde la sede central:
       aplica el mismo INSERT / UPDATE / DELETE de un tipo de cuenta en los
       5 nodos ejecutando el CRUD remoto de cada uno por RPC.
       Si un nodo falla, se compensa (se deshace) lo aplicado en los nodos
       anteriores para que todas las copias sigan iguales. */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_TipoCuenta_Replicar
    @operacion      VARCHAR(10),            -- INSERTAR | ACTUALIZAR | ELIMINAR
    @id_tipo_cuenta INT           = NULL,   -- obligatorio en ACTUALIZAR / ELIMINAR
    @nombre         NVARCHAR(50)  = NULL,
    @descripcion    NVARCHAR(200) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @hechos TABLE (srv SYSNAME, bd SYSNAME);
    DECLARE @ant_nombre NVARCHAR(50), @ant_desc NVARCHAR(200);
    DECLARE @srv SYSNAME, @bd SYSNAME, @proc NVARCHAR(400);

    BEGIN TRY
        IF @operacion NOT IN ('INSERTAR','ACTUALIZAR','ELIMINAR')
            THROW 50081, N'Operación no válida (INSERTAR, ACTUALIZAR, ELIMINAR).', 1;

        IF @operacion = 'INSERTAR'
        BEGIN
            IF EXISTS (SELECT 1 FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta WHERE nombre = @nombre)
                THROW 50082, N'Ya existe un tipo de cuenta con ese nombre.', 1;
            -- El id lo asigna la sede central para que sea el mismo en todos los nodos
            SELECT @id_tipo_cuenta = ISNULL(MAX(id_tipo_cuenta), 0) + 1 FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta;
        END
        ELSE
        BEGIN
            SELECT @ant_nombre = nombre, @ant_desc = descripcion
            FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta;
            IF @ant_nombre IS NULL
                THROW 50083, N'El tipo de cuenta no existe.', 1;
        END;

        -- Medellín (copia maestra) primero: si alli falla, no se toca ningun otro nodo
        DECLARE c CURSOR LOCAL FAST_FORWARD FOR
            SELECT linked_server, base_datos FROM dbo.Nodos ORDER BY es_sede_central DESC, id_nodo;
        OPEN c;
        FETCH NEXT FROM c INTO @srv, @bd;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            SET @proc = QUOTENAME(@srv) + N'.' + QUOTENAME(@bd) + N'.dbo.sp_TipoCuenta_' +
                        CASE @operacion WHEN 'INSERTAR' THEN N'Insertar' WHEN 'ACTUALIZAR' THEN N'Actualizar' ELSE N'Eliminar' END;

            IF @operacion = 'INSERTAR'
                EXEC @proc @id_tipo_cuenta = @id_tipo_cuenta, @nombre = @nombre, @descripcion = @descripcion;
            ELSE IF @operacion = 'ACTUALIZAR'
                EXEC @proc @id_tipo_cuenta = @id_tipo_cuenta, @nombre = @nombre, @descripcion = @descripcion;
            ELSE
                EXEC @proc @id_tipo_cuenta = @id_tipo_cuenta;

            INSERT INTO @hechos VALUES (@srv, @bd);
            FETCH NEXT FROM c INTO @srv, @bd;
        END
        CLOSE c; DEALLOCATE c;

        SELECT N'Operación ' + @operacion + N' replicada en los 5 nodos' AS mensaje, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF CURSOR_STATUS('local', 'c') >= 0 BEGIN CLOSE c; DEALLOCATE c; END;

        -- Compensacion en los nodos donde ya se habia aplicado la operacion
        DECLARE k CURSOR LOCAL FAST_FORWARD FOR SELECT srv, bd FROM @hechos;
        OPEN k;
        FETCH NEXT FROM k INTO @srv, @bd;
        WHILE @@FETCH_STATUS = 0
        BEGIN
            BEGIN TRY
                IF @operacion = 'INSERTAR'
                BEGIN
                    SET @proc = QUOTENAME(@srv) + N'.' + QUOTENAME(@bd) + N'.dbo.sp_TipoCuenta_Eliminar';
                    EXEC @proc @id_tipo_cuenta = @id_tipo_cuenta;
                END
                ELSE IF @operacion = 'ACTUALIZAR'
                BEGIN
                    SET @proc = QUOTENAME(@srv) + N'.' + QUOTENAME(@bd) + N'.dbo.sp_TipoCuenta_Actualizar';
                    EXEC @proc @id_tipo_cuenta = @id_tipo_cuenta, @nombre = @ant_nombre, @descripcion = @ant_desc;
                END
                ELSE
                BEGIN
                    SET @proc = QUOTENAME(@srv) + N'.' + QUOTENAME(@bd) + N'.dbo.sp_TipoCuenta_Insertar';
                    EXEC @proc @id_tipo_cuenta = @id_tipo_cuenta, @nombre = @ant_nombre, @descripcion = @ant_desc;
                END;
            END TRY
            BEGIN CATCH
                PRINT N'Advertencia: no se pudo compensar en ' + @srv + N': ' + ERROR_MESSAGE();
            END CATCH;
            FETCH NEXT FROM k INTO @srv, @bd;
        END
        CLOSE k; DEALLOCATE k;

        THROW;
    END CATCH
END;
GO

/* G.7 Verificar la consistencia de los catalogos replicados:
       compara la copia de cada nodo contra la copia maestra (Medellín). */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_VerificarReplicacion
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT n.ciudad AS nodo,
               (SELECT COUNT(*) FROM dbo.vw_Dist_TiposCuenta t WHERE t.id_nodo = n.id_nodo)          AS tipos_cuenta,
               (SELECT COUNT(*) FROM dbo.vw_Dist_ProductosFinancieros p WHERE p.id_nodo = n.id_nodo) AS productos,
               CASE WHEN EXISTS (
                        -- diferencias entre la copia del nodo y la maestra (en ambos sentidos)
                        (SELECT id_tipo_cuenta, nombre, descripcion FROM dbo.vw_Dist_TiposCuenta WHERE id_nodo = n.id_nodo
                         EXCEPT
                         SELECT id_tipo_cuenta, nombre, descripcion FROM dbo.vw_Dist_TiposCuenta WHERE id_nodo = 1)
                        UNION ALL
                        (SELECT id_tipo_cuenta, nombre, descripcion FROM dbo.vw_Dist_TiposCuenta WHERE id_nodo = 1
                         EXCEPT
                         SELECT id_tipo_cuenta, nombre, descripcion FROM dbo.vw_Dist_TiposCuenta WHERE id_nodo = n.id_nodo))
                    OR EXISTS (
                        (SELECT id_producto, nombre, categoria, tasa_interes, activo FROM dbo.vw_Dist_ProductosFinancieros WHERE id_nodo = n.id_nodo
                         EXCEPT
                         SELECT id_producto, nombre, categoria, tasa_interes, activo FROM dbo.vw_Dist_ProductosFinancieros WHERE id_nodo = 1)
                        UNION ALL
                        (SELECT id_producto, nombre, categoria, tasa_interes, activo FROM dbo.vw_Dist_ProductosFinancieros WHERE id_nodo = 1
                         EXCEPT
                         SELECT id_producto, nombre, categoria, tasa_interes, activo FROM dbo.vw_Dist_ProductosFinancieros WHERE id_nodo = n.id_nodo))
                    THEN N'DIFERENTE A LA MAESTRA' ELSE N'SINCRONIZADO' END AS estado_replica
        FROM dbo.Nodos n
        ORDER BY n.id_nodo;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

PRINT N'>> Procedimientos almacenados creados correctamente.';
GO


-- #####################################################################
-- ARCHIVO: 07_Vistas.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 07 : VISTAS (BancoCentral)
     1. vw_ClientesRegistradosActuales
     2. vw_PrestamosDetalladoPorCliente
     3. vw_PagosPorCliente
     4. vw_CuentasActivas
     5. vw_Distribuida_CuentasSucursalTipo   (consulta los Linked Servers)
     6. vw_Distribuida_EmpleadosPorSede      (OPENQUERY a los 5 nodos)
   Vistas GLOBALES de los nodos de sucursal (UNION ALL por Linked Server):
     vw_Dist_Sucursales, vw_Dist_Empleados, vw_Dist_TiposCuenta,
     vw_Dist_ProductosFinancieros, vw_Dist_Auditoria
   ===================================================================== */
USE BancoCentral;
GO

/* =====================================================================
   0. VISTAS GLOBALES (transparencia de ubicacion)
   La sede central ve cada tabla de las sucursales como una sola tabla,
   aunque fisicamente este repartida en 5 nodos. Cada SELECT viaja por el
   Linked Server de su ciudad con nombre de 4 partes.
   ===================================================================== */
CREATE OR ALTER VIEW dbo.vw_Dist_Sucursales
AS
SELECT 1 AS id_nodo, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM SRV_MEDELLIN.BancoMedellin.dbo.Sucursales
UNION ALL SELECT 2, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM SRV_BOGOTA.BancoBogota.dbo.Sucursales
UNION ALL SELECT 3, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM SRV_CARTAGENA.BancoCartagena.dbo.Sucursales
UNION ALL SELECT 4, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM SRV_SANANDRES.BancoSanAndres.dbo.Sucursales
UNION ALL SELECT 5, id_sucursal, nombre, ciudad, direccion, es_sede_central FROM SRV_CALI.BancoCali.dbo.Sucursales;
GO

CREATE OR ALTER VIEW dbo.vw_Dist_Empleados
AS
SELECT 1 AS id_nodo, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM SRV_MEDELLIN.BancoMedellin.dbo.Empleados
UNION ALL SELECT 2, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM SRV_BOGOTA.BancoBogota.dbo.Empleados
UNION ALL SELECT 3, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM SRV_CARTAGENA.BancoCartagena.dbo.Empleados
UNION ALL SELECT 4, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM SRV_SANANDRES.BancoSanAndres.dbo.Empleados
UNION ALL SELECT 5, id_empleado, nombre, documento, cargo, id_sucursal, activo FROM SRV_CALI.BancoCali.dbo.Empleados;
GO

-- Catalogos replicados: muestra la copia de CADA nodo (sirve para verificar la replicacion)
CREATE OR ALTER VIEW dbo.vw_Dist_TiposCuenta
AS
SELECT 1 AS id_nodo, id_tipo_cuenta, nombre, descripcion FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta
UNION ALL SELECT 2, id_tipo_cuenta, nombre, descripcion FROM SRV_BOGOTA.BancoBogota.dbo.TiposCuenta
UNION ALL SELECT 3, id_tipo_cuenta, nombre, descripcion FROM SRV_CARTAGENA.BancoCartagena.dbo.TiposCuenta
UNION ALL SELECT 4, id_tipo_cuenta, nombre, descripcion FROM SRV_SANANDRES.BancoSanAndres.dbo.TiposCuenta
UNION ALL SELECT 5, id_tipo_cuenta, nombre, descripcion FROM SRV_CALI.BancoCali.dbo.TiposCuenta;
GO

CREATE OR ALTER VIEW dbo.vw_Dist_ProductosFinancieros
AS
SELECT 1 AS id_nodo, id_producto, nombre, categoria, tasa_interes, descripcion, activo FROM SRV_MEDELLIN.BancoMedellin.dbo.ProductosFinancieros
UNION ALL SELECT 2, id_producto, nombre, categoria, tasa_interes, descripcion, activo FROM SRV_BOGOTA.BancoBogota.dbo.ProductosFinancieros
UNION ALL SELECT 3, id_producto, nombre, categoria, tasa_interes, descripcion, activo FROM SRV_CARTAGENA.BancoCartagena.dbo.ProductosFinancieros
UNION ALL SELECT 4, id_producto, nombre, categoria, tasa_interes, descripcion, activo FROM SRV_SANANDRES.BancoSanAndres.dbo.ProductosFinancieros
UNION ALL SELECT 5, id_producto, nombre, categoria, tasa_interes, descripcion, activo FROM SRV_CALI.BancoCali.dbo.ProductosFinancieros;
GO

CREATE OR ALTER VIEW dbo.vw_Dist_Auditoria
AS
SELECT N'Medellín' AS nodo, id_auditoria, base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos, usuario, fecha FROM SRV_MEDELLIN.BancoMedellin.dbo.Auditoria
UNION ALL SELECT N'Bogotá',     id_auditoria, base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos, usuario, fecha FROM SRV_BOGOTA.BancoBogota.dbo.Auditoria
UNION ALL SELECT N'Cartagena',  id_auditoria, base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos, usuario, fecha FROM SRV_CARTAGENA.BancoCartagena.dbo.Auditoria
UNION ALL SELECT N'San Andrés', id_auditoria, base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos, usuario, fecha FROM SRV_SANANDRES.BancoSanAndres.dbo.Auditoria
UNION ALL SELECT N'Cali',       id_auditoria, base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos, usuario, fecha FROM SRV_CALI.BancoCali.dbo.Auditoria;
GO

/* 1. Clientes registrados actualmente (estado ACTIVO) con su resumen */
CREATE OR ALTER VIEW dbo.vw_ClientesRegistradosActuales
AS
SELECT  c.id_cliente,
        c.nombre,
        c.documento,
        c.tipo_cliente,
        c.direccion,
        c.telefono,
        c.fecha_registro,
        (SELECT COUNT(*) FROM dbo.Cuentas x   WHERE x.id_cliente = c.id_cliente AND x.estado <> 'CERRADA')         AS cuentas_abiertas,
        (SELECT COUNT(*) FROM dbo.Prestamos p WHERE p.id_cliente = c.id_cliente AND p.estado IN ('ACTIVO','MORA')) AS prestamos_vigentes,
        dbo.fn_SaldoTotalCliente(c.id_cliente)                                                                     AS saldo_total
FROM dbo.Clientes c
WHERE c.estado = 'ACTIVO';
GO

/* 2. Prestamos detallado por cliente */
CREATE OR ALTER VIEW dbo.vw_PrestamosDetalladoPorCliente
AS
SELECT  c.id_cliente,
        c.nombre                                                       AS cliente,
        c.documento,
        p.id_prestamo,
        pf.nombre                                                      AS producto,
        p.fecha_desembolso,
        p.monto                                                        AS capital,
        p.interes                                                      AS tasa_anual,
        p.plazo                                                        AS plazo_meses,
        dbo.fn_CalcularTotalPrestamo(p.monto, p.interes, p.plazo)      AS total_a_pagar,
        CAST(dbo.fn_CalcularTotalPrestamo(p.monto, p.interes, p.plazo) / p.plazo AS DECIMAL(18,2)) AS cuota_mensual,
        ISNULL(pg.total_pagado, 0)                                     AS total_pagado,
        ISNULL(pg.cantidad_pagos, 0)                                   AS cantidad_pagos,
        p.saldo_pendiente,
        CAST(100.0 * ISNULL(pg.total_pagado, 0)
             / dbo.fn_CalcularTotalPrestamo(p.monto, p.interes, p.plazo) AS DECIMAL(5,2)) AS porcentaje_pagado,
        p.estado
FROM dbo.Prestamos p
JOIN dbo.Clientes c ON c.id_cliente = p.id_cliente
LEFT JOIN dbo.syn_ProductosFinancieros pf ON pf.id_producto = p.id_producto
OUTER APPLY (SELECT SUM(g.monto) AS total_pagado, COUNT(*) AS cantidad_pagos
             FROM dbo.Pagos g WHERE g.id_prestamo = p.id_prestamo) pg;
GO

/* 3. Pagos por cliente (detalle de cada pago con su prestamo y cliente) */
CREATE OR ALTER VIEW dbo.vw_PagosPorCliente
AS
SELECT  c.id_cliente,
        c.nombre        AS cliente,
        c.documento,
        p.id_prestamo,
        g.id_pago,
        g.fecha         AS fecha_pago,
        g.monto         AS monto_pago,
        SUM(g.monto) OVER (PARTITION BY p.id_prestamo ORDER BY g.fecha, g.id_pago
                           ROWS UNBOUNDED PRECEDING) AS acumulado_prestamo,
        p.estado        AS estado_prestamo
FROM dbo.Pagos g
JOIN dbo.Prestamos p ON p.id_prestamo = g.id_prestamo
JOIN dbo.Clientes  c ON c.id_cliente  = p.id_cliente;
GO

/* 4. Cuentas activas (con nombres de tipo y sucursal desde los nodos de sucursal) */
CREATE OR ALTER VIEW dbo.vw_CuentasActivas
AS
SELECT  cu.id_cuenta,
        cu.numero_cuenta,
        c.id_cliente,
        c.nombre        AS cliente,
        tc.nombre       AS tipo_cuenta,
        s.nombre        AS sucursal,
        s.ciudad,
        cu.saldo,
        cu.fecha_apertura
FROM dbo.Cuentas cu
JOIN dbo.Clientes c ON c.id_cliente = cu.id_cliente
LEFT JOIN dbo.syn_TiposCuenta tc ON tc.id_tipo_cuenta = cu.id_tipo_cuenta
LEFT JOIN dbo.vw_Sucursales   s  ON s.id_sucursal     = cu.id_sucursal
WHERE cu.estado = 'ACTIVA';
GO

/* 5. VISTA DISTRIBUIDA: cuentas locales + sucursal (nodo de su ciudad) y tipo de
      cuenta (nodo Medellín), accedidos por los Linked Servers (4 partes). */
CREATE OR ALTER VIEW dbo.vw_Distribuida_CuentasSucursalTipo
AS
SELECT  cu.id_cuenta,
        cu.numero_cuenta,
        c.nombre        AS cliente,
        c.tipo_cliente,
        tc.nombre       AS tipo_cuenta,
        tc.descripcion  AS descripcion_tipo,
        s.nombre        AS sucursal,
        s.ciudad,
        CASE WHEN s.es_sede_central = 1 THEN N'SEDE CENTRAL' ELSE N'SUCURSAL' END AS tipo_sede,
        cu.saldo,
        cu.estado
FROM dbo.Cuentas cu
JOIN dbo.Clientes c ON c.id_cliente = cu.id_cliente
JOIN SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta tc ON tc.id_tipo_cuenta = cu.id_tipo_cuenta
JOIN dbo.vw_Dist_Sucursales                     s  ON s.id_sucursal     = cu.id_sucursal;
GO

/* 6. VISTA DISTRIBUIDA con OPENQUERY: empleados por sede. Cada consulta se
      resuelve completa en el nodo de su ciudad y solo viaja el resultado. */
CREATE OR ALTER VIEW dbo.vw_Distribuida_EmpleadosPorSede
AS
SELECT * FROM OPENQUERY(SRV_MEDELLIN,
     'SELECT s.ciudad, s.nombre AS sede, e.id_empleado, e.nombre AS empleado, e.cargo,
             CASE WHEN e.activo = 1 THEN ''ACTIVO'' ELSE ''INACTIVO'' END AS estado
      FROM BancoMedellin.dbo.Empleados e JOIN BancoMedellin.dbo.Sucursales s ON s.id_sucursal = e.id_sucursal')
UNION ALL
SELECT * FROM OPENQUERY(SRV_BOGOTA,
     'SELECT s.ciudad, s.nombre AS sede, e.id_empleado, e.nombre AS empleado, e.cargo,
             CASE WHEN e.activo = 1 THEN ''ACTIVO'' ELSE ''INACTIVO'' END AS estado
      FROM BancoBogota.dbo.Empleados e JOIN BancoBogota.dbo.Sucursales s ON s.id_sucursal = e.id_sucursal')
UNION ALL
SELECT * FROM OPENQUERY(SRV_CARTAGENA,
     'SELECT s.ciudad, s.nombre AS sede, e.id_empleado, e.nombre AS empleado, e.cargo,
             CASE WHEN e.activo = 1 THEN ''ACTIVO'' ELSE ''INACTIVO'' END AS estado
      FROM BancoCartagena.dbo.Empleados e JOIN BancoCartagena.dbo.Sucursales s ON s.id_sucursal = e.id_sucursal')
UNION ALL
SELECT * FROM OPENQUERY(SRV_SANANDRES,
     'SELECT s.ciudad, s.nombre AS sede, e.id_empleado, e.nombre AS empleado, e.cargo,
             CASE WHEN e.activo = 1 THEN ''ACTIVO'' ELSE ''INACTIVO'' END AS estado
      FROM BancoSanAndres.dbo.Empleados e JOIN BancoSanAndres.dbo.Sucursales s ON s.id_sucursal = e.id_sucursal')
UNION ALL
SELECT * FROM OPENQUERY(SRV_CALI,
     'SELECT s.ciudad, s.nombre AS sede, e.id_empleado, e.nombre AS empleado, e.cargo,
             CASE WHEN e.activo = 1 THEN ''ACTIVO'' ELSE ''INACTIVO'' END AS estado
      FROM BancoCali.dbo.Empleados e JOIN BancoCali.dbo.Sucursales s ON s.id_sucursal = e.id_sucursal');
GO

PRINT N'>> Vistas creadas correctamente.';
GO


-- #####################################################################
-- ARCHIVO: 08_Datos_Principal.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 08 : DATOS DE PRUEBA DE LA BASE PRINCIPAL (BancoCentral)
   IMPORTANTE: se ejecuta DESPUES de los triggers, de modo que:
     - Las cuentas se crean con saldo 0 y su saldo se construye con
       las transacciones (el trigger lo actualiza automaticamente).
     - El saldo pendiente de cada prestamo lo calcula el trigger.
     - Los pagos descuentan el saldo del prestamo (trigger).
     - Todo queda registrado en BancoMedellin.dbo.Auditoria (nodo de la sede central).
   ===================================================================== */
USE BancoCentral;
GO
SET NOCOUNT ON;
GO

/* ---------------------------------------------------------------------
   1. CLIENTES
   --------------------------------------------------------------------- */
INSERT INTO dbo.Clientes (nombre, documento, direccion, telefono, tipo_cliente, fecha_registro) VALUES
(N'Juan Pablo Pérez Gómez',        '1017123456',  N'Cra 43A # 1-50, Medellín',          '3001234567', 'NATURAL',  '2026-01-05'),
(N'María Fernanda López Ruiz',     '43123456',    N'Calle 72 # 10-34, Bogotá',          '3102345678', 'NATURAL',  '2026-01-08'),
(N'Carlos Andrés Ramírez Díaz',    '1020456789',  N'Barrio Manga Cl 25 # 20-10, Cartagena', '3153456789', 'NATURAL', '2026-01-12'),
(N'Ana Sofía Torres Pomare',       '1143567890',  N'Av. Providencia # 4-12, San Andrés', '3164567890', 'NATURAL',  '2026-01-15'),
(N'Inversiones del Valle S.A.S.',  '900123456-1', N'Av. 3N # 45-20, Cali',              '6023456789', 'JURIDICO', '2026-01-20'),
(N'Luis Eduardo Martínez Silva',   '79876543',    N'Calle 100 # 15-20, Bogotá',         '3115678901', 'NATURAL',  '2026-01-22'),
(N'Comercializadora Caribe Ltda.', '800987654-3', N'Zona Industrial Mamonal, Cartagena', '6056789012', 'JURIDICO', '2026-01-25'),
(N'Valentina Restrepo Uribe',      '1036654321',  N'Calle 10 # 43-15, Medellín',        '3006789012', 'NATURAL',  '2026-02-02'),
(N'Jorge Iván Castaño Ríos',       '98765432',    N'Cra 70 # 44-30, Medellín',          '3017890123', 'NATURAL',  '2026-02-02'),
(N'Paola Andrea Mosquera Mina',    '1144098765',  N'Calle 5 # 66-40, Cali',             '3188901234', 'NATURAL',  '2026-02-05'),
(N'Tecnología Andina S.A.S.',      '901234567-8', N'Milla de Oro, Medellín',            '6049012345', 'JURIDICO', '2026-02-10'),
(N'Camilo Herrera Bent',           '1001234567',  N'Sound Bay, San Andrés',             '3129012345', 'NATURAL',  '2026-02-12');
GO

/* ---------------------------------------------------------------------
   2. CUENTAS (saldo 0; tipo y sucursal referencian los nodos de sucursal)
      Tipos (catalogo replicado): 1 Ahorros, 2 Corriente, 3 Nomina, 4 Ahorro programado
      Sucursales (una por nodo): 1 Medellin (central, BancoMedellin), 2 Bogota (BancoBogota),
                 3 Cartagena (BancoCartagena), 4 San Andres (BancoSanAndres), 5 Cali (BancoCali)
   --------------------------------------------------------------------- */
INSERT INTO dbo.Cuentas (numero_cuenta, id_cliente, id_tipo_cuenta, id_sucursal, saldo, fecha_apertura) VALUES
('AH-0001',  1, 1, 1, 0, '2026-01-05'),
('CO-0002',  1, 2, 1, 0, '2026-01-05'),
('AH-0003',  2, 1, 2, 0, '2026-01-08'),
('NO-0004',  2, 3, 2, 0, '2026-01-08'),
('AH-0005',  3, 1, 3, 0, '2026-01-12'),
('AH-0006',  4, 1, 4, 0, '2026-01-15'),
('CO-0007',  5, 2, 5, 0, '2026-01-20'),
('AH-0008',  5, 1, 5, 0, '2026-01-20'),
('AH-0009',  6, 1, 2, 0, '2026-01-22'),
('CO-0010',  7, 2, 3, 0, '2026-01-25'),
('AH-0011',  8, 1, 1, 0, '2026-02-02'),
('NO-0012',  9, 3, 1, 0, '2026-02-02'),
('AH-0013', 10, 1, 5, 0, '2026-02-05'),
('CO-0014', 11, 2, 1, 0, '2026-02-10'),
('AP-0015', 11, 4, 1, 0, '2026-02-10'),
('AP-0016',  8, 4, 1, 0, '2026-02-15');
GO

/* ---------------------------------------------------------------------
   3. TRANSACCIONES (en orden cronologico; el trigger actualiza saldos)
   --------------------------------------------------------------------- */
-- 3.1 Depositos de apertura
INSERT INTO dbo.Transacciones (id_cuenta, tipo, monto, fecha, id_cuenta_destino, descripcion) VALUES
( 1, 'DEPOSITO',  5000000, '2026-01-05 09:00', NULL, N'Depósito de apertura'),
( 2, 'DEPOSITO', 12000000, '2026-01-05 09:30', NULL, N'Depósito de apertura'),
( 3, 'DEPOSITO',  3500000, '2026-01-08 10:00', NULL, N'Depósito de apertura'),
( 4, 'DEPOSITO',  2800000, '2026-01-08 11:00', NULL, N'Pago de nómina enero'),
( 5, 'DEPOSITO',  1200000, '2026-01-12 08:45', NULL, N'Depósito de apertura'),
( 6, 'DEPOSITO',   900000, '2026-01-15 14:00', NULL, N'Depósito de apertura'),
( 7, 'DEPOSITO', 45000000, '2026-01-20 10:15', NULL, N'Capital de trabajo'),
( 8, 'DEPOSITO',  8000000, '2026-01-20 10:30', NULL, N'Depósito de apertura'),
( 9, 'DEPOSITO',  2100000, '2026-01-22 16:00', NULL, N'Depósito de apertura'),
(10, 'DEPOSITO', 30000000, '2026-01-25 09:10', NULL, N'Depósito de apertura'),
(11, 'DEPOSITO',  1500000, '2026-02-02 11:20', NULL, N'Depósito de apertura'),
(12, 'DEPOSITO',  3200000, '2026-02-02 11:40', NULL, N'Pago de nómina febrero'),
(13, 'DEPOSITO',   750000, '2026-02-05 15:00', NULL, N'Depósito de apertura'),
(14, 'DEPOSITO', 60000000, '2026-02-10 09:00', NULL, N'Depósito de apertura'),
(15, 'DEPOSITO', 10000000, '2026-02-10 09:05', NULL, N'Aporte inicial ahorro programado'),
(16, 'DEPOSITO',   400000, '2026-02-15 10:00', NULL, N'Aporte inicial ahorro programado');
GO

-- 3.2 Movimientos del año
INSERT INTO dbo.Transacciones (id_cuenta, tipo, monto, fecha, id_cuenta_destino, descripcion) VALUES
( 4, 'DEPOSITO',      2800000, '2026-02-28 12:00', NULL, N'Pago de nómina febrero'),
( 1, 'RETIRO',         800000, '2026-03-03 10:00', NULL, N'Retiro en cajero'),
( 2, 'TRANSFERENCIA', 1500000, '2026-03-10 14:30',    3, N'Pago de servicios profesionales'),
( 7, 'TRANSFERENCIA', 5000000, '2026-03-15 09:00',   10, N'Pago a proveedor'),
( 4, 'DEPOSITO',      2800000, '2026-03-31 12:00', NULL, N'Pago de nómina marzo'),
(12, 'DEPOSITO',      3200000, '2026-04-02 08:00', NULL, N'Pago de nómina marzo'),
( 3, 'RETIRO',         600000, '2026-04-10 17:00', NULL, N'Retiro en oficina'),
(14, 'RETIRO',       15000000, '2026-04-18 11:00', NULL, N'Compra de equipos'),
( 8, 'DEPOSITO',      1000000, '2026-05-05 10:00', NULL, N'Consignación'),
( 9, 'RETIRO',         300000, '2026-05-20 13:30', NULL, N'Retiro en cajero'),
(10, 'TRANSFERENCIA', 2000000, '2026-06-01 09:00',    7, N'Devolución de anticipo'),
( 1, 'DEPOSITO',      1200000, '2026-06-15 15:45', NULL, N'Prima de junio'),
( 5, 'RETIRO',         200000, '2026-07-03 10:00', NULL, N'Retiro en cajero'),
(11, 'TRANSFERENCIA',  500000, '2026-07-20 11:10',    1, N'Pago de arriendo'),
(13, 'DEPOSITO',       350000, '2026-08-08 09:30', NULL, N'Consignación'),
( 6, 'RETIRO',         150000, '2026-08-25 16:20', NULL, N'Retiro en cajero'),
(15, 'DEPOSITO',      2000000, '2026-09-10 10:00', NULL, N'Aporte ahorro programado'),
(12, 'RETIRO',        1000000, '2026-09-30 12:00', NULL, N'Retiro en oficina');
GO

-- 3.3 Patron ANOMALO: 5 retiros seguidos en menos de 30 minutos (cuenta AH-0009)
INSERT INTO dbo.Transacciones (id_cuenta, tipo, monto, fecha, descripcion) VALUES
(9, 'RETIRO', 200000, '2026-10-15 22:01', N'Retiro en cajero'),
(9, 'RETIRO', 250000, '2026-10-15 22:07', N'Retiro en cajero'),
(9, 'RETIRO', 300000, '2026-10-15 22:12', N'Retiro en cajero'),
(9, 'RETIRO', 280000, '2026-10-15 22:18', N'Retiro en cajero'),
(9, 'RETIRO', 150000, '2026-10-15 22:25', N'Retiro en cajero');
GO

-- 3.4 Movimientos recientes
INSERT INTO dbo.Transacciones (id_cuenta, tipo, monto, fecha, id_cuenta_destino, descripcion) VALUES
( 1, 'TRANSFERENCIA', 700000, '2026-11-03 10:00',    2, N'Traslado entre cuentas propias'),
( 4, 'RETIRO',       1000000, '2026-11-05 09:00', NULL, N'Retiro en oficina'),
( 3, 'DEPOSITO',      400000, '2026-11-10 14:00', NULL, N'Consignación'),
( 1, 'RETIRO',        300000, '2026-11-12 11:00', NULL, N'Retiro en cajero');
GO

/* ---------------------------------------------------------------------
   4. PRESTAMOS (el trigger calcula saldo_pendiente = capital + interes)
      Productos: 1 Libre inversion, 2 Hipotecario, 3 Vehicular, 4 Empresarial
   --------------------------------------------------------------------- */
INSERT INTO dbo.Prestamos (id_cliente, id_producto, monto, interes, plazo, fecha_desembolso) VALUES
( 1, 1,  10000000, 18.00,  24, '2026-02-01'),   -- 1
( 2, 3,  25000000, 15.00,  36, '2026-03-01'),   -- 2
( 3, 1,   5000000, 12.00,  12, '2026-01-15'),   -- 3 (se pagara completo)
( 5, 4,  80000000, 14.00,  48, '2026-02-15'),   -- 4
( 7, 4,  50000000, 14.00,  24, '2026-04-01'),   -- 5
( 9, 1,   3000000, 20.00,  12, '2026-05-10'),   -- 6 (quedara en MORA)
(11, 4, 120000000, 13.00,  60, '2026-06-01'),   -- 7
( 6, 3,  18000000, 16.00,  36, '2026-07-01'),   -- 8
( 8, 2, 200000000, 11.00, 180, '2026-08-01'),   -- 9 (mayor deuda)
( 4, 1,   2000000, 18.00,  12, '2026-03-20');   -- 10
GO

/* ---------------------------------------------------------------------
   5. PAGOS (el trigger descuenta del saldo y cambia estado a PAGADO)
   --------------------------------------------------------------------- */
INSERT INTO dbo.Pagos (id_prestamo, monto, fecha) VALUES
(1,  566667, '2026-03-01'), (1,  566667, '2026-04-01'), (1,  566667, '2026-05-01'), (1,  566667, '2026-06-01'),
(2, 1006944, '2026-04-01'), (2, 1006944, '2026-05-01'), (2, 1006944, '2026-06-01'),
(3, 2800000, '2026-07-15'), (3, 2800000, '2026-10-15'),
(4, 2600000, '2026-03-15'), (4, 2600000, '2026-04-15'), (4, 2600000, '2026-05-15'), (4, 2600000, '2026-06-15'),
(5, 2666667, '2026-05-01'), (5, 2666667, '2026-06-01'),
(6,  300000, '2026-06-10'), (6,  300000, '2026-07-10'),
(7, 3300000, '2026-07-01'), (7, 3300000, '2026-08-01'), (7, 3300000, '2026-09-01'),
(8,  740000, '2026-08-01'),
(9, 2944444, '2026-09-01'), (9, 2944444, '2026-10-01'),
(10, 196667, '2026-04-20');
GO

-- El prestamo 6 deja de pagar desde agosto -> pasa a MORA
UPDATE dbo.Prestamos SET estado = 'MORA' WHERE id_prestamo = 6;
GO

/* ---------------------------------------------------------------------
   6. VERIFICACION RAPIDA
   --------------------------------------------------------------------- */
SELECT 'Clientes' AS tabla, COUNT(*) AS registros FROM dbo.Clientes
UNION ALL SELECT 'Cuentas',       COUNT(*) FROM dbo.Cuentas
UNION ALL SELECT 'Transacciones', COUNT(*) FROM dbo.Transacciones
UNION ALL SELECT 'Prestamos',     COUNT(*) FROM dbo.Prestamos
UNION ALL SELECT 'Pagos',         COUNT(*) FROM dbo.Pagos
UNION ALL SELECT 'Auditoria (nodo Medellín)', COUNT(*) FROM dbo.syn_Auditoria;

SELECT id_cuenta, numero_cuenta, saldo FROM dbo.Cuentas ORDER BY id_cuenta;
SELECT id_prestamo, monto, saldo_pendiente, estado FROM dbo.Prestamos ORDER BY id_prestamo;
GO
PRINT N'>> Datos de BancoCentral cargados correctamente.';
GO


-- #####################################################################
-- ARCHIVO: 09_Consultas.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 09 : LAS 14 CONSULTAS SOLICITADAS (BancoCentral)
   Ejecutar cada bloque por separado (seleccionarlo y F5) para tomar
   la evidencia de cada consulta.
   ===================================================================== */
USE BancoCentral;
GO

/* ---------------------------------------------------------------------
   CONSULTA 1. Saldo total por cliente
   LEFT JOIN para incluir clientes sin cuentas (saldo 0). Se excluyen
   las cuentas CERRADAS.
   --------------------------------------------------------------------- */
SELECT  c.id_cliente,
        c.nombre,
        c.tipo_cliente,
        COUNT(cu.id_cuenta)                               AS cantidad_cuentas,
        CAST(ISNULL(SUM(cu.saldo), 0) AS DECIMAL(18,2))   AS saldo_total
FROM dbo.Clientes c
LEFT JOIN dbo.Cuentas cu ON cu.id_cliente = c.id_cliente AND cu.estado <> 'CERRADA'
GROUP BY c.id_cliente, c.nombre, c.tipo_cliente
ORDER BY saldo_total DESC;
GO

/* ---------------------------------------------------------------------
   CONSULTA 2. Promedio de saldo por tipo de cuenta
   (DISTRIBUIDA: el tipo de cuenta esta en el catalogo del nodo Medellín, SRV_MEDELLIN)
   --------------------------------------------------------------------- */
SELECT  tc.id_tipo_cuenta,
        tc.nombre                                          AS tipo_cuenta,
        COUNT(cu.id_cuenta)                                AS cantidad_cuentas,
        CAST(ISNULL(AVG(cu.saldo), 0) AS DECIMAL(18,2))    AS saldo_promedio,
        CAST(ISNULL(MIN(cu.saldo), 0) AS DECIMAL(18,2))    AS saldo_minimo,
        CAST(ISNULL(MAX(cu.saldo), 0) AS DECIMAL(18,2))    AS saldo_maximo
FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta tc
LEFT JOIN dbo.Cuentas cu ON cu.id_tipo_cuenta = tc.id_tipo_cuenta AND cu.estado <> 'CERRADA'
GROUP BY tc.id_tipo_cuenta, tc.nombre
ORDER BY saldo_promedio DESC;
GO

/* ---------------------------------------------------------------------
   CONSULTA 3. Clientes con prestamos activos (ACTIVO o en MORA)
   --------------------------------------------------------------------- */
SELECT  c.id_cliente,
        c.nombre,
        c.documento,
        COUNT(p.id_prestamo)                    AS prestamos_activos,
        SUM(p.monto)                            AS capital_prestado,
        SUM(p.saldo_pendiente)                  AS deuda_pendiente,
        SUM(CASE WHEN p.estado = 'MORA' THEN 1 ELSE 0 END) AS prestamos_en_mora
FROM dbo.Clientes c
JOIN dbo.Prestamos p ON p.id_cliente = c.id_cliente
WHERE p.estado IN ('ACTIVO','MORA')
GROUP BY c.id_cliente, c.nombre, c.documento
ORDER BY deuda_pendiente DESC;
GO

/* ---------------------------------------------------------------------
   CONSULTA 4. Cantidad de cuentas por sucursal (DISTRIBUIDA: las sucursales
   vienen de los 5 nodos a traves de vw_Dist_Sucursales)
   --------------------------------------------------------------------- */
-- 4a. Consulta directa sobre la vista global (5 Linked Servers)
SELECT  s.nombre                 AS sucursal,
        s.ciudad,
        COUNT(cu.id_cuenta)      AS cantidad_cuentas
FROM dbo.vw_Dist_Sucursales s
LEFT JOIN dbo.Cuentas cu ON cu.id_sucursal = s.id_sucursal
GROUP BY s.nombre, s.ciudad
ORDER BY cantidad_cuentas DESC;
GO
-- 4b. Mediante procedimiento distribuido (agrega cuentas activas y saldo)
EXEC dbo.sp_Dist_CuentasPorSucursal;
GO

/* ---------------------------------------------------------------------
   CONSULTA 5. PROCEDIMIENTO: transacciones de un cliente en un rango de fechas
   --------------------------------------------------------------------- */
EXEC dbo.sp_TransaccionesClienteRangoFechas
     @id_cliente   = 1,
     @fecha_inicio = '2026-01-01',
     @fecha_fin    = '2026-12-31';
GO

/* ---------------------------------------------------------------------
   CONSULTA 6. FUNCION: resumen financiero del cliente
   (cuentas, saldo total, prestamos, deuda)
   --------------------------------------------------------------------- */
SELECT * FROM dbo.fn_ResumenFinancieroCliente(1);      -- un cliente
SELECT * FROM dbo.fn_ResumenFinancieroCliente(NULL);   -- todos los clientes
GO

/* ---------------------------------------------------------------------
   CONSULTA 7. Los 5 clientes con mayor saldo total
   WITH TIES incluye empates en la quinta posicion.
   --------------------------------------------------------------------- */
SELECT TOP (5) WITH TIES
        c.id_cliente,
        c.nombre,
        dbo.fn_SaldoTotalCliente(c.id_cliente) AS saldo_total,
        RANK() OVER (ORDER BY dbo.fn_SaldoTotalCliente(c.id_cliente) DESC) AS posicion
FROM dbo.Clientes c
WHERE c.estado = 'ACTIVO'
ORDER BY saldo_total DESC;
GO

/* ---------------------------------------------------------------------
   CONSULTA 8. Cliente con mayor deuda activa
   --------------------------------------------------------------------- */
SELECT TOP (1) WITH TIES
        r.id_cliente,
        r.nombre,
        r.documento,
        r.prestamos_activos,
        r.deuda_activa,
        r.saldo_total,
        r.patrimonio_neto
FROM dbo.fn_ResumenFinancieroCliente(NULL) r
WHERE r.deuda_activa > 0
ORDER BY r.deuda_activa DESC;
GO

/* ---------------------------------------------------------------------
   CONSULTA 9. Ingresos generados por intereses de prestamos
   - interes_proyectado : total a pagar - capital (lo que el banco ganara).
   - interes_cobrado    : parte de los pagos recibidos que corresponde a
                          intereses (proporcional: pagado * interes / total).
   GROUPING SETS agrega la fila de TOTAL GENERAL.
   --------------------------------------------------------------------- */
WITH base AS
(
    SELECT  p.id_prestamo,
            c.nombre                                                   AS cliente,
            p.estado,
            p.monto                                                    AS capital,
            dbo.fn_CalcularTotalPrestamo(p.monto, p.interes, p.plazo)  AS total_a_pagar,
            ISNULL((SELECT SUM(g.monto) FROM dbo.Pagos g WHERE g.id_prestamo = p.id_prestamo), 0) AS pagado
    FROM dbo.Prestamos p
    JOIN dbo.Clientes  c ON c.id_cliente = p.id_cliente
    WHERE p.estado <> 'CANCELADO'
),
calculo AS
(
    SELECT  *,
            total_a_pagar - capital                                         AS interes_proyectado,
            CAST(pagado * (total_a_pagar - capital) / total_a_pagar AS DECIMAL(18,2)) AS interes_cobrado
    FROM base
)
SELECT  CASE WHEN GROUPING(id_prestamo) = 1 THEN N'TOTAL GENERAL' ELSE CAST(id_prestamo AS NVARCHAR(10)) END AS prestamo,
        CASE WHEN GROUPING(id_prestamo) = 1 THEN N'' ELSE cliente END AS cliente,
        SUM(capital)            AS capital,
        SUM(interes_proyectado) AS interes_proyectado,
        SUM(pagado)             AS total_pagado,
        SUM(interes_cobrado)    AS interes_cobrado
FROM calculo
GROUP BY GROUPING SETS ((id_prestamo, cliente), ())
ORDER BY GROUPING(id_prestamo), MIN(id_prestamo);
GO

/* ---------------------------------------------------------------------
   CONSULTA 10. Cuentas con mas de N transacciones en un periodo
   (funcion de tabla parametrizada: N = 3, año 2026)
   --------------------------------------------------------------------- */
SELECT * FROM dbo.fn_CuentasConMasDeNTransacciones(3, '2026-01-01', '2026-12-31')
ORDER BY total_transacciones DESC;
GO

/* ---------------------------------------------------------------------
   CONSULTA 11. Cuentas con posibles anomalias:
   3 o mas retiros dentro de una ventana de 60 minutos
   --------------------------------------------------------------------- */
SELECT * FROM dbo.fn_DetectarAnomaliasRetiros(3, 60);
GO

/* ---------------------------------------------------------------------
   CONSULTA 12. CONSULTA DISTRIBUIDA: clientes + sucursal + tipo de cuenta
   --------------------------------------------------------------------- */
-- 12a. Nombres de 4 partes (Linked Servers de Medellín + vista global de sucursales)
SELECT  c.nombre      AS cliente,
        c.documento,
        cu.numero_cuenta,
        tc.nombre     AS tipo_cuenta,
        s.nombre      AS sucursal,
        s.ciudad,
        cu.saldo
FROM dbo.Clientes c
JOIN dbo.Cuentas  cu ON cu.id_cliente = c.id_cliente
JOIN dbo.vw_Dist_Sucursales  s  ON s.id_sucursal     = cu.id_sucursal
JOIN SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta tc ON tc.id_tipo_cuenta = cu.id_tipo_cuenta
ORDER BY s.ciudad, c.nombre;
GO
-- 12b. Con OPENQUERY dentro de un procedimiento distribuido (filtro opcional por ciudad)
EXEC dbo.sp_Dist_ClientesSucursalTipoCuenta;
EXEC dbo.sp_Dist_ClientesSucursalTipoCuenta @ciudad = N'Medellín';
GO
-- 12c. Mediante la vista distribuida
SELECT * FROM dbo.vw_Distribuida_CuentasSucursalTipo ORDER BY ciudad, cliente;
GO

/* ---------------------------------------------------------------------
   CONSULTA 13. Clientes con cuentas activas, prestamos activos y saldo
   mayor a un valor dado (funcion de tabla; valor = $5.000.000)
   --------------------------------------------------------------------- */
SELECT * FROM dbo.fn_ClientesConProductosYSaldoMayorA(5000000)
ORDER BY saldo_total DESC;
GO

/* ---------------------------------------------------------------------
   CONSULTA 14. Flujo neto por cliente: depositos vs retiros
   - flujo_neto_efectivo : depositos - retiros
   - flujo_neto_total    : (depositos + transferencias recibidas)
                           - (retiros + transferencias enviadas)
   --------------------------------------------------------------------- */
WITH movimientos AS
(
    SELECT co.id_cliente, t.tipo AS concepto, t.monto
    FROM dbo.Transacciones t
    JOIN dbo.Cuentas co ON co.id_cuenta = t.id_cuenta
    UNION ALL
    SELECT cd.id_cliente, 'TRANSFERENCIA_RECIBIDA', t.monto
    FROM dbo.Transacciones t
    JOIN dbo.Cuentas cd ON cd.id_cuenta = t.id_cuenta_destino
)
SELECT  c.id_cliente,
        c.nombre,
        v.depositos,
        v.retiros,
        v.depositos - v.retiros                                           AS flujo_neto_efectivo,
        v.transf_recibidas,
        v.transf_enviadas,
        (v.depositos + v.transf_recibidas) - (v.retiros + v.transf_enviadas) AS flujo_neto_total,
        CASE WHEN v.depositos > v.retiros THEN N'POSITIVO (ahorra)'
             WHEN v.depositos < v.retiros THEN N'NEGATIVO (desahorra)'
             ELSE N'NEUTRO' END                                           AS tendencia
FROM dbo.Clientes c
CROSS APPLY (
    SELECT  CAST(ISNULL(SUM(CASE WHEN m.concepto = 'DEPOSITO'               THEN m.monto END), 0) AS DECIMAL(18,2)) AS depositos,
            CAST(ISNULL(SUM(CASE WHEN m.concepto = 'RETIRO'                 THEN m.monto END), 0) AS DECIMAL(18,2)) AS retiros,
            CAST(ISNULL(SUM(CASE WHEN m.concepto = 'TRANSFERENCIA_RECIBIDA' THEN m.monto END), 0) AS DECIMAL(18,2)) AS transf_recibidas,
            CAST(ISNULL(SUM(CASE WHEN m.concepto = 'TRANSFERENCIA'          THEN m.monto END), 0) AS DECIMAL(18,2)) AS transf_enviadas
    FROM movimientos m
    WHERE m.id_cliente = c.id_cliente
) v
ORDER BY flujo_neto_efectivo DESC;
GO

/* ---------------------------------------------------------------------
   VISTAS (evidencia)
   --------------------------------------------------------------------- */
SELECT * FROM dbo.vw_ClientesRegistradosActuales ORDER BY saldo_total DESC;
SELECT * FROM dbo.vw_PrestamosDetalladoPorCliente ORDER BY cliente, id_prestamo;
SELECT * FROM dbo.vw_PagosPorCliente ORDER BY cliente, id_prestamo, fecha_pago;
SELECT * FROM dbo.vw_CuentasActivas ORDER BY ciudad, cliente;
SELECT * FROM dbo.vw_Distribuida_CuentasSucursalTipo;
SELECT * FROM dbo.vw_Distribuida_EmpleadosPorSede ORDER BY ciudad, empleado;
GO


-- #####################################################################
-- ARCHIVO: 10_Pruebas_Evidencias.sql
-- #####################################################################
/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 10 : PRUEBAS Y EVIDENCIAS
     Parte 1. Evidencia del Linked Server
     Parte 2. CRUD de Clientes
     Parte 3. CRUD de Cuentas
     Parte 4. CRUD de Transacciones (validaciones de fondos)
     Parte 5. CRUD de Prestamos (control de integridad)
     Parte 6. CRUD de Pagos
     Parte 7. Procedimientos distribuidos y CRUD remoto por RPC
     Parte 8. Triggers de la base remota
     Parte 9. Auditoria
   Las pruebas marcadas [ERROR ESPERADO] DEBEN fallar: el CATCH muestra
   el mensaje que generan las validaciones / triggers.
   Recomendacion: ejecutar parte por parte y tomar captura de pantalla.
   ===================================================================== */
USE BancoCentral;
GO

/* =====================================================================
   PARTE 1. EVIDENCIA DEL LINKED SERVER
   ===================================================================== */
SELECT name AS linked_server, provider, data_source, catalog,
       is_data_access_enabled AS acceso_datos, is_rpc_out_enabled AS rpc_out
FROM sys.servers WHERE is_linked = 1 AND name LIKE N'SRV[_]%';

EXEC master.dbo.sp_testlinkedserver N'SRV_MEDELLIN';
EXEC master.dbo.sp_testlinkedserver N'SRV_BOGOTA';
EXEC master.dbo.sp_testlinkedserver N'SRV_CARTAGENA';
EXEC master.dbo.sp_testlinkedserver N'SRV_SANANDRES';
EXEC master.dbo.sp_testlinkedserver N'SRV_CALI';
EXEC master.dbo.sp_testlinkedserver N'SRV_CENTRAL';

-- Directorio de nodos que usa la sede central
SELECT * FROM dbo.Nodos;
-- Consulta remota pura (4 partes) a un nodo
SELECT * FROM SRV_SANANDRES.BancoSanAndres.dbo.Empleados;
-- Consulta remota con OPENQUERY
SELECT * FROM OPENQUERY(SRV_CALI, 'SELECT * FROM BancoCali.dbo.ProductosFinancieros');
-- Vista global: las 5 sucursales reconstruidas desde los 5 nodos
SELECT * FROM dbo.vw_Dist_Sucursales;
-- Consulta de acceso distribuido: une datos locales (Cuentas) con remotos (Sucursales de los 5 nodos)
SELECT s.ciudad, COUNT(*) AS cuentas, SUM(cu.saldo) AS saldo
FROM dbo.Cuentas cu
JOIN dbo.vw_Dist_Sucursales s ON s.id_sucursal = cu.id_sucursal
GROUP BY s.ciudad;
-- Los catalogos replicados estan sincronizados en todos los nodos
EXEC dbo.sp_Dist_VerificarReplicacion;
GO
-- Comunicacion directa entre sucursales: el nodo de Cartagena consulta al de San Andrés
USE BancoCartagena;
GO
SELECT N'Desde BancoCartagena' AS origen, s.* FROM SRV_SANANDRES.BancoSanAndres.dbo.Sucursales s;
GO
USE BancoCentral;
GO

/* =====================================================================
   PARTE 2. CRUD CLIENTES
   ===================================================================== */
-- Insertar
EXEC dbo.sp_Cliente_Insertar @nombre = N'Cliente de Prueba Uno', @documento = 'TEST-001',
     @direccion = N'Calle Falsa 123, Medellín', @telefono = '3000000001', @tipo_cliente = 'NATURAL';
-- Consultar
EXEC dbo.sp_Cliente_Consultar @documento = 'TEST-001';
GO
-- Actualizar
DECLARE @id INT = (SELECT id_cliente FROM dbo.Clientes WHERE documento = 'TEST-001');
EXEC dbo.sp_Cliente_Actualizar @id_cliente = @id, @telefono = '3009999999', @direccion = N'Nueva dirección 456';
EXEC dbo.sp_Cliente_Consultar @id_cliente = @id;
-- Eliminar (no tiene productos -> borrado fisico)
EXEC dbo.sp_Cliente_Eliminar @id_cliente = @id;
GO

-- [ERROR ESPERADO] documento duplicado
BEGIN TRY
    EXEC dbo.sp_Cliente_Insertar @nombre = N'Duplicado', @documento = '1017123456';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Cliente duplicado' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] eliminar cliente con cuentas abiertas (trigger INSTEAD OF DELETE)
BEGIN TRY
    EXEC dbo.sp_Cliente_Eliminar @id_cliente = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar cliente con cuentas' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

/* =====================================================================
   PARTE 3. CRUD CUENTAS
   ===================================================================== */
-- Insertar (valida tipo y sucursal en el servidor remoto; saldo inicial = deposito)
EXEC dbo.sp_Cuenta_Insertar @numero_cuenta = 'AH-0017', @id_cliente = 12,
     @id_tipo_cuenta = 1, @id_sucursal = 4, @saldo_inicial = 500000;
-- Cuenta sin movimientos (para probar borrado fisico)
EXEC dbo.sp_Cuenta_Insertar @numero_cuenta = 'AH-0018', @id_cliente = 12,
     @id_tipo_cuenta = 1, @id_sucursal = 4, @saldo_inicial = 0;
-- Consultar (procedimiento distribuido)
EXEC dbo.sp_Cuenta_Consultar @id_cliente = 12;
GO
-- Actualizar: bloquear y volver a activar
DECLARE @c INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0017');
EXEC dbo.sp_Cuenta_Actualizar @id_cuenta = @c, @estado = 'BLOQUEADA';
EXEC dbo.sp_Cuenta_Actualizar @id_cuenta = @c, @estado = 'ACTIVA', @id_sucursal = 1;
-- Eliminar cuenta sin movimientos -> borrado fisico
DECLARE @c2 INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0018');
EXEC dbo.sp_Cuenta_Eliminar @id_cuenta = @c2;
GO

-- [ERROR ESPERADO] tipo de cuenta inexistente en el servidor remoto
BEGIN TRY
    EXEC dbo.sp_Cuenta_Insertar @numero_cuenta = 'XX-9999', @id_cliente = 1, @id_tipo_cuenta = 99, @id_sucursal = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Tipo de cuenta inexistente (SP)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] saldo inicial negativo
BEGIN TRY
    EXEC dbo.sp_Cuenta_Insertar @numero_cuenta = 'XX-9998', @id_cliente = 1, @id_tipo_cuenta = 1, @id_sucursal = 1, @saldo_inicial = -100;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Saldo inicial negativo' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] INSERT directo (sin SP) con sucursal inexistente -> lo detiene el TRIGGER
BEGIN TRY
    INSERT INTO dbo.Cuentas (numero_cuenta, id_cliente, id_tipo_cuenta, id_sucursal) VALUES ('XX-9997', 1, 1, 77);
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Sucursal inexistente (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] modificar el saldo directamente -> lo detiene el TRIGGER
BEGIN TRY
    UPDATE dbo.Cuentas SET saldo = 999999999 WHERE id_cuenta = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Modificar saldo a mano (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] eliminar una cuenta con saldo -> trigger INSTEAD OF DELETE
BEGIN TRY
    DECLARE @c INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0017');
    EXEC dbo.sp_Cuenta_Eliminar @id_cuenta = @c;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar cuenta con saldo (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

/* =====================================================================
   PARTE 4. CRUD TRANSACCIONES
   ===================================================================== */
DECLARE @c INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0017');
-- Insertar: deposito, retiro y transferencia (el trigger actualiza los saldos)
EXEC dbo.sp_Transaccion_Insertar @id_cuenta = @c, @tipo = 'DEPOSITO', @monto = 250000, @descripcion = N'Consignación de prueba';
EXEC dbo.sp_Transaccion_Insertar @id_cuenta = @c, @tipo = 'RETIRO',   @monto = 100000, @descripcion = N'Retiro de prueba';
EXEC dbo.sp_Transaccion_Insertar @id_cuenta = @c, @tipo = 'TRANSFERENCIA', @monto = 150000,
     @id_cuenta_destino = 6, @descripcion = N'Transferencia de prueba';
-- Consultar
EXEC dbo.sp_Transaccion_Consultar @id_cuenta = @c;
-- Actualizar (solo descripcion)
DECLARE @t INT = (SELECT MAX(id_transaccion) FROM dbo.Transacciones WHERE id_cuenta = @c);
EXEC dbo.sp_Transaccion_Actualizar @id_transaccion = @t, @descripcion = N'Transferencia de prueba (corregida)';
GO

-- [ERROR ESPERADO] retiro mayor al saldo (no permitir saldo negativo)
BEGIN TRY
    DECLARE @c INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0017');
    EXEC dbo.sp_Transaccion_Insertar @id_cuenta = @c, @tipo = 'RETIRO', @monto = 10000000;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Retiro sin saldo suficiente' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] transferencia sin fondos
BEGIN TRY
    DECLARE @c INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0017');
    EXEC dbo.sp_Transaccion_Insertar @id_cuenta = @c, @tipo = 'TRANSFERENCIA', @monto = 10000000, @id_cuenta_destino = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Transferencia sin fondos' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] INSERT directo de un retiro sin fondos -> lo detiene el TRIGGER
BEGIN TRY
    INSERT INTO dbo.Transacciones (id_cuenta, tipo, monto) VALUES (6, 'RETIRO', 99999999);
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Retiro sin fondos (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] modificar el monto de una transaccion -> TRIGGER (son inmutables)
BEGIN TRY
    UPDATE dbo.Transacciones SET monto = 1 WHERE id_transaccion = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Modificar monto de transacción' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

-- Eliminar = ANULAR el deposito de prueba: el trigger revierte el saldo
DECLARE @c INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0017');
DECLARE @t INT = (SELECT id_transaccion FROM dbo.Transacciones
                  WHERE id_cuenta = @c AND tipo = 'DEPOSITO' AND descripcion = N'Consignación de prueba');
SELECT N'Saldo antes de anular' AS momento, saldo FROM dbo.Cuentas WHERE id_cuenta = @c;
EXEC dbo.sp_Transaccion_Eliminar @id_transaccion = @t;
SELECT N'Saldo después de anular' AS momento, saldo FROM dbo.Cuentas WHERE id_cuenta = @c;

-- Retirar todo el saldo y cerrar la cuenta (tiene historial -> cierre logico)
DECLARE @saldo DECIMAL(18,2) = (SELECT saldo FROM dbo.Cuentas WHERE id_cuenta = @c);
EXEC dbo.sp_Transaccion_Insertar @id_cuenta = @c, @tipo = 'RETIRO', @monto = @saldo, @descripcion = N'Retiro total para cierre';
EXEC dbo.sp_Cuenta_Eliminar @id_cuenta = @c;
EXEC dbo.sp_Cuenta_Consultar @id_cuenta = @c;
GO

-- [ERROR ESPERADO] movimiento sobre una cuenta CERRADA
BEGIN TRY
    DECLARE @c INT = (SELECT id_cuenta FROM dbo.Cuentas WHERE numero_cuenta = 'AH-0017');
    EXEC dbo.sp_Transaccion_Insertar @id_cuenta = @c, @tipo = 'DEPOSITO', @monto = 1000;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Depósito en cuenta cerrada' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

/* =====================================================================
   PARTE 5. CRUD PRESTAMOS (control de integridad)
   ===================================================================== */
-- Insertar: la tasa se toma del producto remoto (Crédito de libre inversión = 18 %)
EXEC dbo.sp_Prestamo_Insertar @id_cliente = 12, @monto = 4000000, @plazo = 12, @id_producto = 1;
-- Consultar (distribuido: nombre del producto desde SRV_MEDELLIN)
EXEC dbo.sp_Prestamo_Consultar @id_cliente = 12;
GO
-- Actualizar: cambiar el plazo (aun sin pagos -> el trigger reliquida el saldo)
DECLARE @p INT = (SELECT MAX(id_prestamo) FROM dbo.Prestamos WHERE id_cliente = 12);
EXEC dbo.sp_Prestamo_Actualizar @id_prestamo = @p, @plazo = 24;
-- Registrar un pago
EXEC dbo.sp_Pago_Insertar @id_prestamo = @p, @monto = 500000;
GO

-- [ERROR ESPERADO] cambiar el monto de un prestamo que ya tiene pagos
BEGIN TRY
    DECLARE @p INT = (SELECT MAX(id_prestamo) FROM dbo.Prestamos WHERE id_cliente = 12);
    EXEC dbo.sp_Prestamo_Actualizar @id_prestamo = @p, @monto = 6000000;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Cambiar monto con pagos (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] modificar el saldo pendiente a mano
BEGIN TRY
    UPDATE dbo.Prestamos SET saldo_pendiente = 0 WHERE id_prestamo = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Modificar saldo pendiente (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] marcar PAGADO un prestamo con saldo
BEGIN TRY
    EXEC dbo.sp_Prestamo_Actualizar @id_prestamo = 1, @estado = 'PAGADO';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'PAGADO con saldo (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] eliminar un prestamo con pagos
BEGIN TRY
    EXEC dbo.sp_Prestamo_Eliminar @id_prestamo = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar préstamo con pagos (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] producto que no es de credito (5 = Cuenta de ahorros)
BEGIN TRY
    EXEC dbo.sp_Prestamo_Insertar @id_cliente = 12, @monto = 1000000, @plazo = 6, @id_producto = 5;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Producto no es crédito' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- Maximo 3 prestamos vigentes: el cliente 12 ya tiene 1, se crean 2 mas y el 4.o falla
EXEC dbo.sp_Prestamo_Insertar @id_cliente = 12, @monto = 1000000, @plazo = 6, @interes = 20;
EXEC dbo.sp_Prestamo_Insertar @id_cliente = 12, @monto = 1500000, @plazo = 6, @interes = 20;
GO
BEGIN TRY
    EXEC dbo.sp_Prestamo_Insertar @id_cliente = 12, @monto = 2000000, @plazo = 6, @interes = 20;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Cuarto préstamo vigente (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- Eliminar los dos prestamos sin pagos (permitido)
DECLARE @p1 INT = (SELECT id_prestamo FROM dbo.Prestamos WHERE id_cliente = 12 AND monto = 1000000);
DECLARE @p2 INT = (SELECT id_prestamo FROM dbo.Prestamos WHERE id_cliente = 12 AND monto = 1500000);
EXEC dbo.sp_Prestamo_Eliminar @id_prestamo = @p1;
EXEC dbo.sp_Prestamo_Eliminar @id_prestamo = @p2;
GO
-- [ERROR ESPERADO] prestamo a cliente INACTIVO (SP y trigger)
EXEC dbo.sp_Cliente_Insertar @nombre = N'Cliente Inactivo', @documento = 'TEST-002';
DECLARE @id INT = (SELECT id_cliente FROM dbo.Clientes WHERE documento = 'TEST-002');
EXEC dbo.sp_Cliente_Actualizar @id_cliente = @id, @estado = 'INACTIVO';
GO
BEGIN TRY
    DECLARE @id INT = (SELECT id_cliente FROM dbo.Clientes WHERE documento = 'TEST-002');
    INSERT INTO dbo.Prestamos (id_cliente, monto, interes, plazo) VALUES (@id, 1000000, 15, 12);
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Préstamo a cliente inactivo (trigger)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

/* =====================================================================
   PARTE 6. CRUD PAGOS
   ===================================================================== */
DECLARE @p INT = (SELECT MAX(id_prestamo) FROM dbo.Prestamos WHERE id_cliente = 12);
DECLARE @g INT = (SELECT MAX(id_pago) FROM dbo.Pagos WHERE id_prestamo = @p);
-- Consultar
EXEC dbo.sp_Pago_Consultar @id_prestamo = @p;
-- Actualizar el monto (el trigger ajusta la diferencia en el saldo del prestamo)
EXEC dbo.sp_Pago_Actualizar @id_pago = @g, @monto = 600000;
EXEC dbo.sp_Prestamo_Consultar @id_prestamo = @p;
-- Eliminar (anular) el pago: el saldo se restituye
EXEC dbo.sp_Pago_Eliminar @id_pago = @g;
EXEC dbo.sp_Prestamo_Consultar @id_prestamo = @p;
GO

-- [ERROR ESPERADO] pago mayor a la deuda
BEGIN TRY
    DECLARE @p INT = (SELECT MAX(id_prestamo) FROM dbo.Prestamos WHERE id_cliente = 12);
    EXEC dbo.sp_Pago_Insertar @id_prestamo = @p, @monto = 99000000;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Pago mayor a la deuda' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- Pagar el total -> el trigger marca el prestamo como PAGADO
DECLARE @p INT = (SELECT MAX(id_prestamo) FROM dbo.Prestamos WHERE id_cliente = 12);
DECLARE @saldo DECIMAL(18,2) = (SELECT saldo_pendiente FROM dbo.Prestamos WHERE id_prestamo = @p);
EXEC dbo.sp_Pago_Insertar @id_prestamo = @p, @monto = @saldo;
GO
-- [ERROR ESPERADO] pago a un prestamo ya PAGADO
BEGIN TRY
    DECLARE @p INT = (SELECT MAX(id_prestamo) FROM dbo.Prestamos WHERE id_cliente = 12);
    EXEC dbo.sp_Pago_Insertar @id_prestamo = @p, @monto = 1000;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Pago a préstamo PAGADO' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

/* =====================================================================
   PARTE 7. PROCEDIMIENTOS DISTRIBUIDOS Y CRUD REMOTO (RPC)
   ===================================================================== */
EXEC dbo.sp_Dist_ResumenSedes;
EXEC dbo.sp_Dist_CuentasPorSucursal;
EXEC dbo.sp_Dist_ClientesSucursalTipoCuenta @ciudad = N'Cali';
-- Escribir en un nodo desde la sede central: el SP enruta al nodo de San Andrés (sucursal 4)
EXEC dbo.sp_Dist_RegistrarEmpleado @nombre = N'Empleado de Prueba Remoto', @documento = '9999999999',
     @cargo = N'Cajero', @id_sucursal = 4;
EXEC SRV_SANANDRES.BancoSanAndres.dbo.sp_Empleado_Consultar @id_sucursal = 4;
GO
-- Limpiar el empleado de prueba (CRUD remoto por RPC)
DECLARE @e INT = (SELECT id_empleado FROM SRV_SANANDRES.BancoSanAndres.dbo.Empleados WHERE documento = '9999999999');
EXEC SRV_SANANDRES.BancoSanAndres.dbo.sp_Empleado_Eliminar @id_empleado = @e;
GO
-- [ERROR ESPERADO] registrar un empleado en una sucursal que no existe en ningun nodo
BEGIN TRY
    EXEC dbo.sp_Dist_RegistrarEmpleado @nombre = N'X', @documento = '8888888888', @cargo = N'Cajero', @id_sucursal = 77;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Sucursal inexistente (enrutamiento)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

-- CRUD de un catalogo REPLICADO: la sede central lo aplica en los 5 nodos
EXEC dbo.sp_Dist_TipoCuenta_Replicar @operacion = 'INSERTAR', @nombre = N'Cuenta Joven', @descripcion = N'Cuenta para menores de 25 años';
SELECT * FROM dbo.vw_Dist_TiposCuenta WHERE nombre = N'Cuenta Joven';   -- 5 filas, una por nodo
DECLARE @tc INT = (SELECT id_tipo_cuenta FROM SRV_MEDELLIN.BancoMedellin.dbo.TiposCuenta WHERE nombre = N'Cuenta Joven');
EXEC dbo.sp_Dist_TipoCuenta_Replicar @operacion = 'ACTUALIZAR', @id_tipo_cuenta = @tc, @descripcion = N'Cuenta sin cuota de manejo para jóvenes';
EXEC SRV_CALI.BancoCali.dbo.sp_TipoCuenta_Consultar @id_tipo_cuenta = @tc;   -- el cambio llegó a Cali
EXEC dbo.sp_Dist_TipoCuenta_Replicar @operacion = 'ELIMINAR', @id_tipo_cuenta = @tc;
EXEC dbo.sp_Dist_VerificarReplicacion;
GO
-- [ERROR ESPERADO] eliminar en todos los nodos un tipo de cuenta usado en BancoCentral
--                  (falla en el primer nodo y no se toca ninguno de los demas)
BEGIN TRY
    EXEC dbo.sp_Dist_TipoCuenta_Replicar @operacion = 'ELIMINAR', @id_tipo_cuenta = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar tipo de cuenta en uso (replicado)' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
EXEC dbo.sp_Dist_VerificarReplicacion;
GO

-- CRUD de Sucursales y Empleados ejecutado en el nodo de Bogotá
EXEC SRV_BOGOTA.BancoBogota.dbo.sp_Sucursal_Insertar @nombre = N'Sucursal Bogotá Norte', @direccion = N'Calle 140 # 9-20';
EXEC SRV_BOGOTA.BancoBogota.dbo.sp_Sucursal_Consultar;
DECLARE @s INT = (SELECT id_sucursal FROM SRV_BOGOTA.BancoBogota.dbo.Sucursales WHERE nombre = N'Sucursal Bogotá Norte');  -- id 201
EXEC SRV_BOGOTA.BancoBogota.dbo.sp_Sucursal_Actualizar @id_sucursal = @s, @direccion = N'Calle 147 # 7-70';
EXEC dbo.sp_Dist_RegistrarEmpleado @nombre = N'Empleado Bogotá Norte', @documento = '9999999998', @cargo = N'Cajero', @id_sucursal = @s;
DECLARE @e INT = (SELECT id_empleado FROM SRV_BOGOTA.BancoBogota.dbo.Empleados WHERE documento = '9999999998');
EXEC SRV_BOGOTA.BancoBogota.dbo.sp_Empleado_Actualizar @id_empleado = @e, @id_sucursal = 2, @cargo = N'Asesor Comercial';
EXEC SRV_BOGOTA.BancoBogota.dbo.sp_Empleado_Eliminar   @id_empleado = @e;
EXEC SRV_BOGOTA.BancoBogota.dbo.sp_Sucursal_Eliminar   @id_sucursal = @s;
GO
-- [ERROR ESPERADO] crear una sucursal de otra ciudad en el nodo de Bogotá (fragmentacion por ciudad)
BEGIN TRY
    EXEC SRV_BOGOTA.BancoBogota.dbo.sp_Sucursal_Insertar @nombre = N'Sucursal Cali Sur', @ciudad = N'Cali';
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Sucursal de otra ciudad en el nodo' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

/* =====================================================================
   PARTE 8. TRIGGERS DE LOS NODOS DE SUCURSAL
   ===================================================================== */
USE BancoMedellin;
GO
-- [ERROR ESPERADO] eliminar un tipo de cuenta usado en BancoCentral
BEGIN TRY
    DELETE FROM dbo.TiposCuenta WHERE id_tipo_cuenta = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar tipo de cuenta en uso' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] eliminar la sede central
BEGIN TRY
    DELETE FROM dbo.Sucursales WHERE es_sede_central = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar sede central' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] eliminar un producto usado por prestamos
BEGIN TRY
    DELETE FROM dbo.ProductosFinancieros WHERE id_producto = 1;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar producto en uso' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] alterar el historial de auditoria
BEGIN TRY
    DELETE FROM dbo.Auditoria;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Borrar auditoría' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO
-- [ERROR ESPERADO] eliminar una sucursal con cuentas en BancoCentral (nodo Cali)
USE BancoCali;
GO
BEGIN TRY
    BEGIN TRANSACTION;   -- todo se deshace al final: es solo una prueba
        DELETE FROM dbo.Empleados WHERE id_sucursal = 5;    -- se libera la sucursal de empleados...
        DELETE FROM dbo.Sucursales WHERE id_sucursal = 5;   -- ...pero tiene cuentas en BancoCentral
    ROLLBACK TRANSACTION;
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK;
    SELECT N'Eliminar sucursal con cuentas' AS prueba, ERROR_NUMBER() AS codigo, ERROR_MESSAGE() AS mensaje_esperado;
END CATCH
GO

/* =====================================================================
   PARTE 9. AUDITORIA DE TODOS LOS NODOS (consultada desde la sede central)
   ===================================================================== */
USE BancoCentral;
GO
EXEC dbo.sp_Dist_ConsultarAuditoria @top = 30;
EXEC dbo.sp_Dist_ConsultarAuditoria @tabla = N'Transacciones', @top = 10;
EXEC dbo.sp_Dist_ConsultarAuditoria @ciudad = N'Bogotá';

SELECT nodo, base_datos, tabla, operacion, COUNT(*) AS registros
FROM dbo.vw_Dist_Auditoria
GROUP BY nodo, base_datos, tabla, operacion
ORDER BY nodo, base_datos, tabla, operacion;
GO


