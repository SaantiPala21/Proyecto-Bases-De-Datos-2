/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   Sistema Distribuido para una Entidad Financiera
   ---------------------------------------------------------------------
   SCRIPT 01 : BASE DE DATOS REMOTA  ->  BancoRemoto
   Contiene  : Tipos de cuenta, Sucursales, Empleados,
               Productos financieros e Historial/Auditoria
               + datos, triggers y procedimientos CRUD.
   Ejecutar  : en SSMS, conectado a la instancia, con permisos sysadmin.
   ===================================================================== */
USE master;
GO

/* ---------------------------------------------------------------------
   1. CREACION DE LA BASE DE DATOS
   --------------------------------------------------------------------- */
IF DB_ID(N'BancoRemoto') IS NOT NULL
BEGIN
    ALTER DATABASE BancoRemoto SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE BancoRemoto;
END
GO
CREATE DATABASE BancoRemoto;
GO
USE BancoRemoto;
GO

/* ---------------------------------------------------------------------
   2. TABLAS
   --------------------------------------------------------------------- */
CREATE TABLE dbo.TiposCuenta
(
    id_tipo_cuenta INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_TiposCuenta PRIMARY KEY,
    nombre         NVARCHAR(50)  NOT NULL CONSTRAINT UQ_TiposCuenta_nombre UNIQUE,
    descripcion    NVARCHAR(200) NULL
);
GO

CREATE TABLE dbo.Sucursales
(
    id_sucursal     INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Sucursales PRIMARY KEY,
    nombre          NVARCHAR(80)  NOT NULL CONSTRAINT UQ_Sucursales_nombre UNIQUE,
    ciudad          NVARCHAR(50)  NOT NULL,
    direccion       NVARCHAR(150) NULL,
    es_sede_central BIT NOT NULL CONSTRAINT DF_Sucursales_central DEFAULT (0),
    CONSTRAINT CK_Sucursales_ciudad CHECK (ciudad IN (N'Medellín', N'Bogotá', N'Cartagena', N'San Andrés', N'Cali'))
);
GO
-- Solo puede existir UNA sede central (indice unico filtrado)
CREATE UNIQUE INDEX UX_Sucursales_SedeCentral ON dbo.Sucursales(es_sede_central) WHERE es_sede_central = 1;
GO

CREATE TABLE dbo.Empleados
(
    id_empleado INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Empleados PRIMARY KEY,
    nombre      NVARCHAR(100) NOT NULL,
    documento   VARCHAR(20)   NOT NULL CONSTRAINT UQ_Empleados_documento UNIQUE,
    cargo       NVARCHAR(50)  NOT NULL,
    id_sucursal INT NOT NULL CONSTRAINT FK_Empleados_Sucursales REFERENCES dbo.Sucursales(id_sucursal),
    activo      BIT NOT NULL CONSTRAINT DF_Empleados_activo DEFAULT (1)
);
GO
CREATE INDEX IX_Empleados_sucursal ON dbo.Empleados(id_sucursal);
GO

CREATE TABLE dbo.ProductosFinancieros
(
    id_producto  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ProductosFinancieros PRIMARY KEY,
    nombre       NVARCHAR(80) NOT NULL CONSTRAINT UQ_Productos_nombre UNIQUE,
    categoria    VARCHAR(10)  NOT NULL CONSTRAINT CK_Productos_categoria CHECK (categoria IN ('AHORRO','CREDITO','INVERSION','SEGURO')),
    tasa_interes DECIMAL(5,2) NOT NULL CONSTRAINT CK_Productos_tasa CHECK (tasa_interes BETWEEN 0 AND 100),
    descripcion  NVARCHAR(200) NULL,
    activo       BIT NOT NULL CONSTRAINT DF_Productos_activo DEFAULT (1)
);
GO

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

/* Sinonimos hacia la base principal: permiten que los triggers de esta
   base verifiquen si un registro esta siendo usado en BancoCentral. */
CREATE SYNONYM dbo.syn_CuentasCentral   FOR BancoCentral.dbo.Cuentas;
CREATE SYNONYM dbo.syn_PrestamosCentral FOR BancoCentral.dbo.Prestamos;
GO

/* ---------------------------------------------------------------------
   3. TRIGGERS (minimo uno por tabla)
   --------------------------------------------------------------------- */

-- 3.1 Auditoria de TiposCuenta
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

-- 3.2 Integridad distribuida: no borrar un tipo de cuenta usado en BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_TiposCuenta_EvitarEliminacion ON dbo.TiposCuenta
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_CuentasCentral c ON c.id_tipo_cuenta = d.id_tipo_cuenta)
        THROW 51001, N'No se puede eliminar el tipo de cuenta: existen cuentas en BancoCentral que lo utilizan.', 1;
END;
GO

-- 3.3 Auditoria de Sucursales
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

-- 3.4 Control de Sucursales (INSTEAD OF: valida ANTES de que actuen las FK)
--     no borrar la sede central, ni sucursales con empleados o con cuentas
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

-- 3.5 Auditoria de Empleados
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

-- 3.6 Auditoria de ProductosFinancieros
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

-- 3.7 Integridad distribuida: no borrar un producto usado por prestamos de BancoCentral
CREATE OR ALTER TRIGGER dbo.tr_Productos_EvitarEliminacion ON dbo.ProductosFinancieros
AFTER DELETE
AS
BEGIN
    SET NOCOUNT ON;
    IF EXISTS (SELECT 1 FROM deleted d JOIN dbo.syn_PrestamosCentral p ON p.id_producto = d.id_producto)
        THROW 51004, N'No se puede eliminar el producto: hay préstamos en BancoCentral asociados. Desactívelo (activo = 0).', 1;
END;
GO

-- 3.8 La auditoria es inmutable: no se permite modificar ni borrar el historial
CREATE OR ALTER TRIGGER dbo.tr_Auditoria_Inmutable ON dbo.Auditoria
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 51005, N'El historial de auditoría es de solo lectura: no se permite UPDATE ni DELETE.', 1;
END;
GO

/* ---------------------------------------------------------------------
   4. PROCEDIMIENTOS CRUD (entidades remotas)
   --------------------------------------------------------------------- */

/* ========== TIPOS DE CUENTA ========== */
CREATE OR ALTER PROCEDURE dbo.sp_TipoCuenta_Insertar
    @nombre      NVARCHAR(50),
    @descripcion NVARCHAR(200) = NULL,
    @id_tipo_cuenta INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51101, N'El nombre del tipo de cuenta es obligatorio.', 1;
        IF EXISTS (SELECT 1 FROM dbo.TiposCuenta WHERE nombre = @nombre)
            THROW 51102, N'Ya existe un tipo de cuenta con ese nombre.', 1;

        INSERT INTO dbo.TiposCuenta (nombre, descripcion) VALUES (@nombre, @descripcion);
        SET @id_tipo_cuenta = SCOPE_IDENTITY();
        SELECT N'Tipo de cuenta registrado' AS mensaje, @id_tipo_cuenta AS id_tipo_cuenta;
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
        SELECT id_tipo_cuenta, nombre, descripcion
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
        SELECT N'Tipo de cuenta actualizado' AS mensaje, @id_tipo_cuenta AS id_tipo_cuenta;
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
        SELECT N'Tipo de cuenta eliminado' AS mensaje, @id_tipo_cuenta AS id_tipo_cuenta;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== SUCURSALES ========== */
CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Insertar
    @nombre    NVARCHAR(80),
    @ciudad    NVARCHAR(50),
    @direccion NVARCHAR(150) = NULL,
    @id_sucursal INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF LTRIM(RTRIM(ISNULL(@nombre, N''))) = N''
            THROW 51201, N'El nombre de la sucursal es obligatorio.', 1;
        IF @ciudad NOT IN (N'Medellín', N'Bogotá', N'Cartagena', N'San Andrés', N'Cali')
            THROW 51202, N'Ciudad no válida. Opciones: Medellín, Bogotá, Cartagena, San Andrés, Cali.', 1;

        INSERT INTO dbo.Sucursales (nombre, ciudad, direccion, es_sede_central)
        VALUES (@nombre, @ciudad, @direccion, 0);
        SET @id_sucursal = SCOPE_IDENTITY();
        SELECT N'Sucursal registrada' AS mensaje, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

CREATE OR ALTER PROCEDURE dbo.sp_Sucursal_Consultar
    @id_sucursal INT = NULL,
    @ciudad      NVARCHAR(50) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT s.id_sucursal, s.nombre, s.ciudad, s.direccion,
               CASE WHEN s.es_sede_central = 1 THEN N'SEDE CENTRAL' ELSE N'Sucursal' END AS tipo_sede,
               (SELECT COUNT(*) FROM dbo.Empleados e WHERE e.id_sucursal = s.id_sucursal AND e.activo = 1) AS empleados_activos
        FROM dbo.Sucursales s
        WHERE (@id_sucursal IS NULL OR s.id_sucursal = @id_sucursal)
          AND (@ciudad IS NULL OR s.ciudad = @ciudad)
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
    @ciudad      NVARCHAR(50)  = NULL,
    @direccion   NVARCHAR(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51203, N'La sucursal no existe.', 1;
        IF @ciudad IS NOT NULL AND @ciudad NOT IN (N'Medellín', N'Bogotá', N'Cartagena', N'San Andrés', N'Cali')
            THROW 51202, N'Ciudad no válida. Opciones: Medellín, Bogotá, Cartagena, San Andrés, Cali.', 1;

        UPDATE dbo.Sucursales
           SET nombre    = COALESCE(@nombre, nombre),
               ciudad    = COALESCE(@ciudad, ciudad),
               direccion = COALESCE(@direccion, direccion)
         WHERE id_sucursal = @id_sucursal;
        SELECT N'Sucursal actualizada' AS mensaje, @id_sucursal AS id_sucursal;
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
            THROW 51203, N'La sucursal no existe.', 1;
        IF EXISTS (SELECT 1 FROM dbo.Empleados WHERE id_sucursal = @id_sucursal)
            THROW 51204, N'No se puede eliminar la sucursal: tiene empleados asignados.', 1;

        DELETE FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal;  -- el trigger valida sede central y cuentas
        SELECT N'Sucursal eliminada' AS mensaje, @id_sucursal AS id_sucursal;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* ========== EMPLEADOS ========== */
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
            THROW 51302, N'Ya existe un empleado con ese documento.', 1;
        IF NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no existe.', 1;

        INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal)
        VALUES (@nombre, @documento, @cargo, @id_sucursal);
        SET @id_empleado = SCOPE_IDENTITY();
        SELECT N'Empleado registrado' AS mensaje, @id_empleado AS id_empleado;
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
               CASE WHEN e.activo = 1 THEN 'ACTIVO' ELSE 'INACTIVO' END AS estado
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
            THROW 51304, N'El empleado no existe.', 1;
        IF @id_sucursal IS NOT NULL AND NOT EXISTS (SELECT 1 FROM dbo.Sucursales WHERE id_sucursal = @id_sucursal)
            THROW 51303, N'La sucursal indicada no existe.', 1;

        UPDATE dbo.Empleados
           SET nombre      = COALESCE(@nombre, nombre),
               cargo       = COALESCE(@cargo, cargo),
               id_sucursal = COALESCE(@id_sucursal, id_sucursal),
               activo      = COALESCE(@activo, activo)
         WHERE id_empleado = @id_empleado;
        SELECT N'Empleado actualizado' AS mensaje, @id_empleado AS id_empleado;
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
            THROW 51304, N'El empleado no existe.', 1;

        DELETE FROM dbo.Empleados WHERE id_empleado = @id_empleado;
        SELECT N'Empleado eliminado' AS mensaje, @id_empleado AS id_empleado;
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END;
GO

/* Consulta de productos financieros (catalogo) */
CREATE OR ALTER PROCEDURE dbo.sp_Producto_Consultar
    @categoria VARCHAR(10) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT id_producto, nombre, categoria, tasa_interes, descripcion, activo
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
   5. DATOS INICIALES
   --------------------------------------------------------------------- */
INSERT INTO dbo.TiposCuenta (nombre, descripcion) VALUES
(N'Ahorros',           N'Cuenta de ahorros tradicional con rendimiento mensual'),
(N'Corriente',         N'Cuenta corriente para manejo de chequera y pagos empresariales'),
(N'Nómina',            N'Cuenta de ahorros para recibir el pago de salario'),
(N'Ahorro programado', N'Cuenta con meta de ahorro y aportes periódicos');
GO

INSERT INTO dbo.Sucursales (nombre, ciudad, direccion, es_sede_central) VALUES
(N'Sede Central Medellín', N'Medellín',   N'Calle 50 # 52-20, La Candelaria', 1),
(N'Sucursal Bogotá',       N'Bogotá',     N'Carrera 7 # 72-41, Chapinero',    0),
(N'Sucursal Cartagena',    N'Cartagena',  N'Av. San Martín # 8-20, Bocagrande', 0),
(N'Sucursal San Andrés',   N'San Andrés', N'Av. Colombia # 1-19, North End',   0),
(N'Sucursal Cali',         N'Cali',       N'Av. 6N # 23-45, Granada',          0);
GO

INSERT INTO dbo.Empleados (nombre, documento, cargo, id_sucursal) VALUES
(N'Laura Gómez Arango',      '1017200001', N'Gerente General',     1),
(N'Andrés Felipe Zapata',    '1017200002', N'Analista de Crédito', 1),
(N'Diana Marcela Ríos',      '1017200003', N'Cajero',              1),
(N'Santiago Rojas Pardo',    '1018200004', N'Gerente de Sucursal', 2),
(N'Natalia Vargas León',     '1018200005', N'Asesor Comercial',    2),
(N'Rafael Núñez Pájaro',     '1047200006', N'Gerente de Sucursal', 3),
(N'Kelly Johanna Barrios',   '1047200007', N'Cajero',              3),
(N'Bryan Archbold Hooker',   '1123200008', N'Gerente de Sucursal', 4),
(N'Shirley Robinson Pomare', '1123200009', N'Asesor Comercial',    4),
(N'Óscar Iván Caicedo',      '1144200010', N'Gerente de Sucursal', 5),
(N'Yuliana Mina Carabalí',   '1144200011', N'Cajero',              5),
(N'Esteban Restrepo Mejía',  '1017200012', N'Auditor Interno',     1);
GO

INSERT INTO dbo.ProductosFinancieros (nombre, categoria, tasa_interes, descripcion) VALUES
(N'Crédito de libre inversión', 'CREDITO',   18.00, N'Préstamo de consumo sin destinación específica'),
(N'Crédito hipotecario',        'CREDITO',   11.00, N'Financiación de vivienda a largo plazo'),
(N'Crédito vehicular',          'CREDITO',   15.00, N'Financiación para compra de vehículo'),
(N'Crédito empresarial',        'CREDITO',   14.00, N'Capital de trabajo para personas jurídicas'),
(N'Cuenta de ahorros',          'AHORRO',     1.50, N'Rendimiento efectivo anual de la cuenta de ahorros'),
(N'CDT 180 días',               'INVERSION',  9.50, N'Certificado de depósito a término fijo'),
(N'Seguro de vida deudor',      'SEGURO',     0.00, N'Seguro obligatorio asociado a créditos');
GO

PRINT N'>> BancoRemoto creada correctamente.';
GO
