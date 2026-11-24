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
