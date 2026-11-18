/* =====================================================================
   BASE DE DATOS II - PROYECTO FINAL TEMA 3
   ---------------------------------------------------------------------
   SCRIPT 05 : TRIGGERS DE LA BASE PRINCIPAL (BancoCentral)
   (Los triggers de la base remota estan en 01_BD_Remota.sql)

   Tabla          Trigger                                   Proposito
   -------------  ----------------------------------------  ------------------------------------------
   Clientes       tr_Clientes_Auditoria                     Historial en BancoRemoto.Auditoria
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
    por eso la validacion contra BancoRemoto se hace en el trigger.) */
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
        THROW 50201, N'El tipo de cuenta no existe en la base remota (BancoRemoto.dbo.TiposCuenta).', 1;

    -- 2. La sucursal debe existir en la base remota
    IF EXISTS (SELECT 1 FROM inserted i
               WHERE NOT EXISTS (SELECT 1 FROM dbo.syn_Sucursales s WHERE s.id_sucursal = i.id_sucursal))
        THROW 50202, N'La sucursal no existe en la base remota (BancoRemoto.dbo.Sucursales).', 1;

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
        THROW 50402, N'El producto financiero no existe en BancoRemoto, no es de categoría CREDITO o está inactivo.', 1;

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
