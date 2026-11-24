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
