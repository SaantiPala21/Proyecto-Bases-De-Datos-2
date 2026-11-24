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
