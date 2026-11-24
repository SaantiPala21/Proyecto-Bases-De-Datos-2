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
