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
