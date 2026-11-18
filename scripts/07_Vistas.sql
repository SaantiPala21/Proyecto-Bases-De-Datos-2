/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 07 : VISTAS (BancoCentral)
     1. vw_ClientesRegistradosActuales
     2. vw_PrestamosDetalladoPorCliente
     3. vw_PagosPorCliente
     4. vw_CuentasActivas
     5. vw_Distribuida_CuentasSucursalTipo   (consulta el Linked Server)
     6. vw_Distribuida_EmpleadosPorSede      (consulta el Linked Server con OPENQUERY)
   ===================================================================== */
USE BancoCentral;
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

/* 4. Cuentas activas (con nombres de tipo y sucursal desde la base remota) */
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
LEFT JOIN dbo.syn_Sucursales  s  ON s.id_sucursal     = cu.id_sucursal
WHERE cu.estado = 'ACTIVA';
GO

/* 5. VISTA DISTRIBUIDA: cuentas locales + sucursal y tipo de cuenta del
      servidor remoto, accedidos por el Linked Server (nombres de 4 partes). */
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
JOIN SRV_REMOTO.BancoRemoto.dbo.TiposCuenta tc ON tc.id_tipo_cuenta = cu.id_tipo_cuenta
JOIN SRV_REMOTO.BancoRemoto.dbo.Sucursales  s  ON s.id_sucursal     = cu.id_sucursal;
GO

/* 6. VISTA DISTRIBUIDA con OPENQUERY: empleados por sede (se resuelve en el remoto) */
CREATE OR ALTER VIEW dbo.vw_Distribuida_EmpleadosPorSede
AS
SELECT *
FROM OPENQUERY(SRV_REMOTO,
     'SELECT s.ciudad, s.nombre AS sede, e.id_empleado, e.nombre AS empleado, e.cargo,
             CASE WHEN e.activo = 1 THEN ''ACTIVO'' ELSE ''INACTIVO'' END AS estado
      FROM BancoRemoto.dbo.Empleados e
      JOIN BancoRemoto.dbo.Sucursales s ON s.id_sucursal = e.id_sucursal');
GO

PRINT N'>> Vistas creadas correctamente.';
GO
