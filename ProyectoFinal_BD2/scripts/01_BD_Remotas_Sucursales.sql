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

