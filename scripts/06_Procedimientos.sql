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
   (El CRUD de TiposCuenta, Sucursales y Empleados esta en la BD remota,
    script 01, y se invoca desde aqui por RPC: SRV_REMOTO.BancoRemoto.dbo.sp_...)
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

/* Acceso DISTRIBUIDO: valida tipo de cuenta y sucursal en SRV_REMOTO
   antes de abrir la transaccion local. */
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
        IF NOT EXISTS (SELECT 1 FROM SRV_REMOTO.BancoRemoto.dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 50015, N'El tipo de cuenta no existe en el servidor remoto.', 1;
        IF NOT EXISTS (SELECT 1 FROM SRV_REMOTO.BancoRemoto.dbo.Sucursales WHERE id_sucursal = @id_sucursal)
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
        LEFT JOIN SRV_REMOTO.BancoRemoto.dbo.TiposCuenta tc ON tc.id_tipo_cuenta = cu.id_tipo_cuenta
        LEFT JOIN SRV_REMOTO.BancoRemoto.dbo.Sucursales  s  ON s.id_sucursal     = cu.id_sucursal
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
           AND NOT EXISTS (SELECT 1 FROM SRV_REMOTO.BancoRemoto.dbo.TiposCuenta WHERE id_tipo_cuenta = @id_tipo_cuenta)
            THROW 50015, N'El tipo de cuenta no existe en el servidor remoto.', 1;
        IF @id_sucursal IS NOT NULL
           AND NOT EXISTS (SELECT 1 FROM SRV_REMOTO.BancoRemoto.dbo.Sucursales WHERE id_sucursal = @id_sucursal)
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
            FROM SRV_REMOTO.BancoRemoto.dbo.ProductosFinancieros
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
        LEFT JOIN SRV_REMOTO.BancoRemoto.dbo.ProductosFinancieros pf ON pf.id_producto = p.id_producto
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
        FROM SRV_REMOTO.BancoRemoto.dbo.Sucursales s
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
        JOIN OPENQUERY(SRV_REMOTO,
             'SELECT s.id_sucursal, s.nombre AS sucursal, s.ciudad,
                     t.id_tipo_cuenta, t.nombre AS tipo_cuenta
              FROM BancoRemoto.dbo.Sucursales s
              CROSS JOIN BancoRemoto.dbo.TiposCuenta t') r
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
        FROM SRV_REMOTO.BancoRemoto.dbo.Sucursales s
        LEFT JOIN (SELECT id_sucursal, COUNT(*) AS empleados
                   FROM SRV_REMOTO.BancoRemoto.dbo.Empleados
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

/* G.4 Registrar un empleado en el servidor remoto ejecutando un
       procedimiento REMOTO (RPC) desde la sede central. */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_RegistrarEmpleado
    @nombre      NVARCHAR(100),
    @documento   VARCHAR(20),
    @cargo       NVARCHAR(50),
    @id_sucursal INT
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        EXEC SRV_REMOTO.BancoRemoto.dbo.sp_Empleado_Insertar
             @nombre      = @nombre,
             @documento   = @documento,
             @cargo       = @cargo,
             @id_sucursal = @id_sucursal;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

/* G.5 Consultar el historial de auditoria almacenado en el servidor remoto */
CREATE OR ALTER PROCEDURE dbo.sp_Dist_ConsultarAuditoria
    @tabla SYSNAME = NULL,
    @desde DATE    = NULL,
    @hasta DATE    = NULL,
    @top   INT     = 100
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        SELECT TOP (@top) a.id_auditoria, a.fecha, a.base_datos, a.tabla, a.operacion,
               a.id_registro, a.usuario, a.datos_anteriores, a.datos_nuevos
        FROM SRV_REMOTO.BancoRemoto.dbo.Auditoria a
        WHERE (@tabla IS NULL OR a.tabla = @tabla)
          AND (@desde IS NULL OR a.fecha >= @desde)
          AND (@hasta IS NULL OR a.fecha <  DATEADD(DAY, 1, @hasta))
        ORDER BY a.id_auditoria DESC;
    END TRY
    BEGIN CATCH
        THROW;
    END CATCH
END;
GO

PRINT N'>> Procedimientos almacenados creados correctamente.';
GO
