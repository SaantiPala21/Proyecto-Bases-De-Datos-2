# Sistema Distribuido para una Entidad Financiera

**Institución Universitaria Pascual Bravo – Base de Datos II – Proyecto Final Tema 3**

| **Motor** | SQL Server 2019 / 2022 (mínimo 2017) |
| **Herramienta** | SQL Server Management Studio (SSMS) |

Base de datos distribuida (simulada) en SQL Server para una entidad financiera con sucursales en **Medellín**, **Bogotá**, **Cartagena**, **San Andrés** y **Cali**, y una **sede central en Medellín** que gestiona todas las sedes. Hay **una base principal** (`BancoCentral`) y **una base remota por sucursal** (5 nodos), conectadas con **un Linked Server por nodo**. Incluye procedimientos CRUD con `TRY...CATCH`, triggers, vistas, funciones definidas por el usuario y 14 consultas de análisis.

---

## Contenido

1. [Estructura del proyecto](#1-estructura-del-proyecto)
2. [Arquitectura](#2-arquitectura)
3. [Requisitos previos](#3-requisitos-previos)
4. [Construcción paso a paso](#4-construcción-paso-a-paso)
5. [Solución de problemas del Linked Server](#5-solución-de-problemas-del-linked-server)
6. [Supuestos](#6-supuestos)
7. [Justificación de la distribución de datos](#7-justificación-de-la-distribución-de-datos)
8. [Modelo de datos y decisiones de modelado](#8-modelo-de-datos-y-decisiones-de-modelado)
9. [Funcionamiento del sistema paso a paso](#9-funcionamiento-del-sistema-paso-a-paso)
10. [Triggers](#10-triggers)
11. [Procedimientos almacenados](#11-procedimientos-almacenados)
12. [Vistas](#12-vistas)
13. [Funciones definidas por el usuario](#13-funciones-definidas-por-el-usuario)
14. [Consultas complejas](#14-consultas-complejas)
15. [Evidencias para la entrega](#15-evidencias-para-la-entrega)
16. [Despliegue opcional en dos servidores reales](#16-despliegue-opcional-en-dos-servidores-reales)
17. [Lista de verificación del enunciado](#17-lista-de-verificación-del-enunciado)

---

## 1. Estructura del proyecto

```
ProyectoFinal_BD2/
├── README.md                              <- este documento
├── Script_Completo_ProyectoFinal.sql      <- scripts 01 a 10 en un solo archivo (entregable)
├── docs/
│   ├── 01_Guia_Construccion_Bases_de_Datos.docx
│   └── 02_Documento_Tecnico_Funcionamiento.docx
└── scripts/
    ├── 00_Ejecutar_Todo.sql            ejecuta 01 a 08 en orden (modo SQLCMD)
    ├── 01_BD_Remotas_Sucursales.sql    5 nodos (BancoMedellin, BancoBogota, BancoCartagena,
    │                                   BancoSanAndres, BancoCali): tablas, triggers, CRUD, datos
    ├── 02_BD_Principal.sql             BancoCentral: tablas, índices, directorio de nodos,
    │                                   sinónimos y vistas de reconstrucción
    ├── 03_Linked_Server.sql            6 Linked Servers (SRV_CENTRAL + uno por sucursal) + pruebas
    ├── 04_Funciones.sql                2 funciones escalares + 4 de tabla
    ├── 05_Triggers.sql                 13 triggers de BancoCentral
    ├── 06_Procedimientos.sql           20 CRUD + consulta 5 + 7 procedimientos distribuidos
    ├── 07_Vistas.sql                   6 vistas de negocio + 5 vistas globales de los nodos
    ├── 08_Datos_Principal.sql      datos de prueba
    ├── 09_Consultas.sql            las 14 consultas
    └── 10_Pruebas_Evidencias.sql   pruebas de CRUD, validaciones, triggers y auditoría
```

---

## 2. Arquitectura

```
                   INSTANCIA SQL SERVER (simula 6 servidores)

                ┌──────────────────────────────────────────┐
                │  BancoCentral  (BASE PRINCIPAL – SEDE    │  SRV_CENTRAL
                │  CENTRAL MEDELLÍN, gestiona todas sedes) │
                │  Clientes · Cuentas · Transacciones ·    │
                │  Préstamos · Pagos · Nodos (directorio)  │
                │  funciones, vistas, SP, triggers         │
                └───────────────────┬──────────────────────┘
                                    │ Linked Servers (4 partes, OPENQUERY, RPC)
    ┌───────────────┬───────────────┼───────────────┬───────────────┐
    ▼               ▼               ▼               ▼               ▼
 BancoMedellin   BancoBogota    BancoCartagena  BancoSanAndres   BancoCali
 SRV_MEDELLIN    SRV_BOGOTA     SRV_CARTAGENA   SRV_SANANDRES    SRV_CALI
 ─────────────   ─────────────  ─────────────   ─────────────    ─────────────
 Cada nodo:  TiposCuenta (replicado) · Sucursales (de su ciudad) · Empleados (de su ciudad)
             ProductosFinancieros (replicado) · Auditoria (historial local) · CRUD y triggers
    ◄────────────── los nodos también se consultan entre sí (malla) ──────────────►
```

| Nodo | Base de datos | Linked Server | Sucursal principal (id) |
|---|---|---|---|
| Principal | `BancoCentral` | `SRV_CENTRAL` | — |
| 1 | `BancoMedellin` | `SRV_MEDELLIN` | Sede Central Medellín (1) |
| 2 | `BancoBogota` | `SRV_BOGOTA` | Sucursal Bogotá (2) |
| 3 | `BancoCartagena` | `SRV_CARTAGENA` | Sucursal Cartagena (3) |
| 4 | `BancoSanAndres` | `SRV_SANANDRES` | Sucursal San Andrés (4) |
| 5 | `BancoCali` | `SRV_CALI` | Sucursal Cali (5) |

La sede central accede a cada sucursal como si fuera otro servidor: nombres de 4 partes (`SRV_BOGOTA.BancoBogota.dbo.Empleados`), `OPENQUERY` y llamadas RPC. Como los Linked Servers se definen a nivel de instancia, **cada nodo puede consultar a cualquier otro** (p. ej. desde `BancoCali`: `SELECT * FROM SRV_BOGOTA.BancoBogota.dbo.Empleados`).

---

## 3. Requisitos previos

| Elemento | Detalle |
|---|---|
| Motor | SQL Server 2019 o 2022 (Developer o Express). Mínimo 2017 (`CREATE OR ALTER`, `FOR JSON`, `THROW`). |
| Herramienta | SSMS 19 o superior. |
| Permisos | Rol **sysadmin** (crear bases de datos y Linked Server). |
| Driver OLE DB | Microsoft OLE DB Driver for SQL Server (`MSOLEDBSQL`). Viene con SQL Server 2019/2022; el script lo detecta solo. |
| Configuración | `nested triggers` = 1 y `RECURSIVE_TRIGGERS` = OFF (valores por defecto). |

Verificación inicial:

```sql
SELECT @@VERSION                     AS version,
       SERVERPROPERTY('ServerName')  AS instancia,
       IS_SRVROLEMEMBER('sysadmin')  AS soy_sysadmin;   -- debe devolver 1

EXEC sp_configure 'nested triggers';                     -- run_value debe ser 1
```

---

## 4. Construcción paso a paso

> **El orden importa.** La base remota va primero porque la principal la referencia; el Linked Server debe existir antes de los procedimientos y vistas que lo usan; los triggers deben existir **antes** de cargar los datos, porque son ellos los que calculan los saldos.

### Atajo: construir todo de una vez

1. Abrir `scripts/00_Ejecutar_Todo.sql` en SSMS.
2. Activar **Consulta → Modo SQLCMD**.
3. Ajustar `:setvar RUTA "..."` a la carpeta de los scripts.
4. Ejecutar (F5). Debe terminar con `CONSTRUCCION FINALIZADA`.

O bien abrir `Script_Completo_ProyectoFinal.sql` y ejecutarlo completo.

### Paso 1 – Bases de datos remotas de las sucursales (`01_BD_Remotas_Sucursales.sql`)

Qué hace (una sección por nodo, repetida para las 5 ciudades):
1. Elimina la versión anterior del proyecto (`BancoRemoto` y `SRV_REMOTO`) si existe.
2. Elimina y crea la base del nodo (`BancoMedellin`, `BancoBogota`, `BancoCartagena`, `BancoSanAndres`, `BancoCali`).
3. Crea `TiposCuenta`, `Sucursales`, `Empleados`, `ProductosFinancieros` y `Auditoria` con PK, UNIQUE, CHECK y la FK Empleados → Sucursales.
4. `Sucursales` solo acepta la ciudad del nodo (`CHECK (ciudad = 'Bogotá')`, etc.). En Medellín un índice único filtrado garantiza **una sola sede central**; en los demás nodos `CHECK (es_sede_central = 0)`.
5. Ids globalmente únicos: la sucursal principal conserva el id 1–5; las nuevas reciben `IDENTITY(N01,1)` (Bogotá 201, 202…), y los empleados `IDENTITY(N001,1)` (Bogotá 2001…).
6. Crea los sinónimos `syn_CuentasCentral` y `syn_PrestamosCentral` hacia BancoCentral.
7. Crea 8 triggers y 13 procedimientos por nodo.
8. Inserta en cada nodo los 4 tipos de cuenta y 7 productos (replicados con los mismos ids), su sucursal y sus empleados.

```sql
SELECT * FROM BancoBogota.dbo.Sucursales;          -- 1 fila: Sucursal Bogotá (id 2)
SELECT COUNT(*) FROM BancoMedellin.dbo.Empleados;  -- 4 (los otros nodos tienen 2)
SELECT COUNT(*) FROM BancoCali.dbo.TiposCuenta;    -- 4 (igual en los 5 nodos)
```

### Paso 2 – Base de datos principal (`02_BD_Principal.sql`)

Qué hace:
1. Crea `BancoCentral` (sede central de Medellín).
2. Crea `Clientes`, `Cuentas`, `Transacciones`, `Prestamos` y `Pagos`. Restricciones clave:
   - `CK_Cuentas_saldo CHECK (saldo >= 0)`: el saldo nunca es negativo.
   - `CK_Transacciones_destino`: la transferencia exige cuenta destino distinta al origen; depósitos y retiros no la tienen.
   - CHECK de dominios: tipo de cliente, estados, montos > 0, plazo 1–360 meses, interés 0–100 %.
3. Crea índices de apoyo.
4. Crea `dbo.Nodos`, el directorio que indica en qué base y Linked Server vive cada ciudad.
5. Crea sinónimos: `syn_TiposCuenta`, `syn_ProductosFinancieros` y `syn_Auditoria` (hacia `BancoMedellin`, la copia maestra) y `syn_Sucursales_XXX` / `syn_Empleados_XXX` para cada nodo.
6. Crea las vistas `vw_Sucursales` y `vw_Empleados`, que reconstruyen las tablas globales con `UNION ALL` de los 5 fragmentos (las usan los triggers).

```sql
USE BancoCentral;
SELECT name FROM sys.tables;                         -- 6 tablas (5 + Nodos)
SELECT name, base_object_name FROM sys.synonyms;     -- 13 sinónimos
SELECT * FROM dbo.vw_Sucursales;                     -- 5 sucursales, una por nodo
```

### Paso 3 – Linked Servers (`03_Linked_Server.sql`)

Qué hace, para cada uno de los 6 nodos (`SRV_CENTRAL`, `SRV_MEDELLIN`, `SRV_BOGOTA`, `SRV_CARTAGENA`, `SRV_SANANDRES`, `SRV_CALI`):
1. Lo elimina si ya existe.
2. Detecta el proveedor instalado (`MSOLEDBSQL19`, `MSOLEDBSQL` o `SQLNCLI11`).
3. Lo crea apuntando a la propia instancia (`SERVERPROPERTY('ServerName')`) con el catálogo del nodo y `TrustServerCertificate=yes`.
4. Login con `@useself = 'True'` (mismas credenciales del usuario conectado).
5. Activa `data access`, `rpc`, `rpc out` y desactiva `remote proc transaction promotion` (no requiere MSDTC).
6. Lo prueba con `sp_testlinkedserver`.

Después muestra las 5 sucursales unidas por 4 partes, un `OPENQUERY`, un RPC y una consulta **entre sucursales** (desde `BancoCali` hacia `SRV_BOGOTA`).

Verificación: seis mensajes *"Linked Server SRV_… verificado"*. En el Explorador de objetos: **Objetos de servidor → Servidores vinculados**.

<details>
<summary>Alternativa gráfica</summary>

Clic derecho en **Servidores vinculados → Nuevo servidor vinculado** (repetir para cada nodo):
- Nombre: `SRV_BOGOTA` · Otro origen de datos · Proveedor: *Microsoft OLE DB Driver for SQL Server*
- Origen de datos: nombre de la instancia (ej. `MIEQUIPO\SQLEXPRESS`) · Catálogo: `BancoBogota`
- Cadena de proveedor: `TrustServerCertificate=yes;`
- Seguridad: *Se establecerán usando el contexto de seguridad actual del inicio de sesión*
- Opciones de servidor: Acceso a datos = True, RPC = True, Salida RPC = True
</details>

### Paso 4 – Funciones (`04_Funciones.sql`)

```sql
SELECT name, type_desc FROM BancoCentral.sys.objects WHERE type IN ('FN','IF','TF');  -- 6 filas
```

### Paso 5 – Triggers (`05_Triggers.sql`)

Crea 13 triggers en BancoCentral (cada nodo de sucursal ya tiene sus 8): **13 + 8 × 5 = 53 en total**, al menos uno por cada tabla de cada base.

```sql
SELECT OBJECT_NAME(parent_id) AS tabla, name,
       CASE WHEN is_instead_of_trigger = 1 THEN 'INSTEAD OF' ELSE 'AFTER' END AS tipo
FROM BancoCentral.sys.triggers ORDER BY tabla;
```

### Paso 6 – Procedimientos (`06_Procedimientos.sql`)

```sql
SELECT name FROM BancoCentral.sys.procedures ORDER BY name;   -- 28 procedimientos
```

### Paso 7 – Vistas (`07_Vistas.sql`)

```sql
SELECT * FROM BancoCentral.dbo.vw_Distribuida_CuentasSucursalTipo;   -- no debe dar error
SELECT * FROM BancoCentral.dbo.vw_Dist_Sucursales;                  -- 5 filas, una por nodo
```

### Paso 8 – Datos de prueba (`08_Datos_Principal.sql`)

Las cuentas se crean con saldo 0 y las transacciones se insertan en orden cronológico: **los triggers construyen los saldos**. Igual con préstamos (el trigger calcula el total a pagar) y pagos (descuentan el saldo y marcan PAGADO al préstamo 3). Se incluye una ráfaga de 5 retiros en 24 minutos en la cuenta `AH-0009` para la consulta de anomalías.

| Tabla | Registros esperados |
|---|---|
| Clientes | 12 |
| Cuentas | 16 |
| Transacciones | 43 |
| Préstamos | 10 (el 3 queda PAGADO y el 6 en MORA) |
| Pagos | 24 |

Saldos de control: `AH-0001` = 4.900.000 · `CO-0002` = 11.200.000 · `AH-0009` = 620.000 · `CO-0014` = 45.000.000.

### Paso 9 – Consultas (`09_Consultas.sql`)

Seleccionar cada bloque `CONSULTA N` y ejecutarlo con F5 para capturar su resultado.

### Paso 10 – Pruebas y evidencias (`10_Pruebas_Evidencias.sql`)

Ejecutar parte por parte. Las pruebas **[ERROR ESPERADO]** deben fallar: el `CATCH` muestra el código y el mensaje, lo que demuestra que la validación o el trigger funcionan.

> El script 10 modifica datos. Para volver al estado inicial, ejecutar de nuevo 01 a 08 (o el 00).

---

## 5. Solución de problemas del Linked Server

| Error | Causa / solución |
|---|---|
| *The certificate chain was issued by an authority that is not trusted* | MSOLEDBSQL 19 exige cifrado. Agregar `TrustServerCertificate=yes` en la cadena de proveedor (el script ya lo hace). |
| *Cannot initialize the data source object of OLE DB provider* | Instalar *Microsoft OLE DB Driver for SQL Server* y reejecutar el script 03. |
| *Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON'* | Solo con otro equipo (doble salto). Usar un login SQL: `sp_addlinkedsrvlogin` con `@useself='False', @rmtuser, @rmtpassword`. |
| *Server 'SRV_BOGOTA' is not configured for DATA ACCESS / RPC* | Reejecutar el script 03. |
| *MSDTC on server is unavailable* | Se escribió a través del Linked Server dentro de una transacción. El diseño lo evita usando sinónimos en los triggers. |
| *CREATE INDEX failed because … 'QUOTED_IDENTIFIER'* | Solo con `sqlcmd` desde consola: agregar el parámetro `-I`. En SSMS no ocurre. |

---

## 6. Supuestos

1. El enunciado menciona "hoteles"; se interpreta como error de redacción y se modelan **sucursales** de la entidad financiera.
2. Distribución simulada: las 6 bases en la misma instancia; Linked Servers *loopback*.
3. Los catálogos (tipos de cuenta y productos) son comunes a todo el banco: se **replican** en los 5 nodos y la copia de Medellín es la maestra.
4. Préstamos con **interés simple anual**: `total = monto × (1 + interés/100 × plazo/12)`; cuota de referencia = `total / plazo`.
5. Los pagos se aplican al saldo total; para ingresos por intereses cada pago se reparte proporcionalmente entre capital e interés.
6. Máximo **3 préstamos vigentes** (ACTIVO o MORA) por cliente.
7. Las transacciones son **inmutables**: no se editan; se anulan (se eliminan y se revierte su efecto) y se registra una nueva.
8. Clientes y cuentas con historial no se borran físicamente: se inactivan / cierran.
9. Valores en pesos colombianos, `DECIMAL(18,2)`.

---

## 7. Justificación de la distribución de datos

| Base | Tablas | Razón |
|---|---|---|
| **BancoCentral** (sede principal, Medellín) | Clientes, Cuentas, Transacciones, Préstamos, Pagos | Datos **transaccionales**: cambian constantemente, exigen consistencia inmediata y se modifican juntos (transacción + saldo; pago + préstamo). Tenerlos en el mismo servidor evita transacciones distribuidas en las operaciones críticas. La sede central gestiona todas las sedes, por eso concentra el núcleo del negocio. |
| **BancoRemoto** | TiposCuenta, Sucursales, Empleados, ProductosFinancieros, Auditoria | Datos de **catálogo y organización** (cambian poco, se consultan mucho) y el **historial de auditoría**. Separar la auditoría impide que quien opera la base transaccional altere el rastro. Los catálogos se administran sin afectar la carga transaccional. |

### Mecanismos de acceso entre servidores

| Mecanismo | Dónde se usa | Por qué |
|---|---|---|
| 4 partes `SRV_REMOTO.BancoRemoto.dbo.Tabla` | Consultas 2, 4, 12; vistas distribuidas; procedimientos de consulta; validaciones en `sp_Cuenta_Insertar` y `sp_Prestamo_Insertar` | Forma estándar; permite JOIN entre tablas locales y remotas. |
| `OPENQUERY(SRV_REMOTO, '...')` | `sp_Dist_ClientesSucursalTipoCuenta`, `vw_Distribuida_EmpleadosPorSede` | La consulta se ejecuta en el remoto y solo viaja el resultado. |
| RPC `EXEC SRV_REMOTO.BancoRemoto.dbo.sp_...` | `sp_Dist_RegistrarEmpleado`, CRUD remoto | La sede central administra los catálogos ejecutando la lógica remota. |
| Sinónimos `syn_*` | Triggers y vistas locales | Ver abajo. |

### ¿Por qué los triggers usan sinónimos y no el Linked Server?

Un trigger siempre se ejecuta **dentro de una transacción**. Acceder a un Linked Server dentro de una transacción la convierte en **transacción distribuida** (MSDTC), y con un Linked Server *loopback* SQL Server no lo permite. Los **sinónimos** (`CREATE SYNONYM dbo.syn_Auditoria FOR BancoRemoto.dbo.Auditoria`) resuelven esto: hoy apuntan con 3 partes y, en un despliegue real, basta recrearlos con 4 partes sin tocar ningún trigger.

---

## 8. Modelo de datos y decisiones de modelado

```
 BancoCentral                                         BancoRemoto
 ─────────────                                        ───────────
 Clientes (1) ──< Cuentas (N) ─ ─ id_tipo_cuenta ─ ─ ► TiposCuenta
     │              │  │ ─ ─ ─ ─ id_sucursal  ─ ─ ─ ─ ► Sucursales (1) ──< Empleados (N)
     │              │  └──< Transacciones (id_cuenta)
     │              └─────< Transacciones (id_cuenta_destino)
     └──< Prestamos (N) ─ ─ ─ id_producto ─ ─ ─ ─ ─ ─ ► ProductosFinancieros
              └──< Pagos (N)
                                                       Auditoria  ◄─ ─ todos los triggers
 ───  llave foránea real (misma base)
 ─ ─  referencia distribuida (validada por trigger)
```

| Tabla | Columnas | Restricciones relevantes |
|---|---|---|
| Clientes | id_cliente, nombre, documento, direccion, telefono, tipo_cliente, estado, fecha_registro | documento UNIQUE; tipo ∈ {NATURAL, JURIDICO}; estado ∈ {ACTIVO, INACTIVO} |
| Cuentas | id_cuenta, numero_cuenta, id_cliente, id_tipo_cuenta, id_sucursal, saldo, estado, fecha_apertura | numero UNIQUE; FK Clientes; **saldo ≥ 0**; estado ∈ {ACTIVA, INACTIVA, BLOQUEADA, CERRADA} |
| Transacciones | id_transaccion, id_cuenta, tipo, monto, fecha, id_cuenta_destino, descripcion | tipo ∈ {DEPOSITO, RETIRO, TRANSFERENCIA}; monto > 0; transferencia con destino ≠ origen |
| Prestamos | id_prestamo, id_cliente, id_producto, monto, interes, plazo, saldo_pendiente, estado, fecha_desembolso | monto > 0; interés 0–100; plazo 1–360; saldo ≥ 0; estado ∈ {ACTIVO, MORA, PAGADO, CANCELADO} |
| Pagos | id_pago, id_prestamo, monto, fecha | FK Prestamos; monto > 0 |
| TiposCuenta | id_tipo_cuenta, nombre, descripcion | nombre UNIQUE |
| Sucursales | id_sucursal, nombre, ciudad, direccion, es_sede_central | ciudad ∈ {Medellín, Bogotá, Cartagena, San Andrés, Cali}; una sola sede central |
| Empleados | id_empleado, nombre, documento, cargo, id_sucursal, activo | FK Sucursales; documento UNIQUE |
| ProductosFinancieros | id_producto, nombre, categoria, tasa_interes, descripcion, activo | categoría ∈ {AHORRO, CREDITO, INVERSION, SEGURO} |
| Auditoria | id_auditoria, base_datos, tabla, operacion, id_registro, datos_anteriores, datos_nuevos, usuario, fecha | operación ∈ {INSERT, UPDATE, DELETE}; datos en JSON |

**Decisiones de modelado**

- **Llaves sustitutas `IDENTITY`** y llaves naturales (documento, número de cuenta) como `UNIQUE`.
- **Sucursal en la cuenta, no en el cliente**: un cliente puede tener cuentas en varias ciudades.
- **Transferencia en una sola fila** (origen + destino): no puede existir un débito sin su crédito.
- **`saldo_pendiente` almacenado** en Préstamos para consultas de deuda inmediatas; su consistencia la garantizan los triggers.
- **Saldo de cuenta controlado**: toda cuenta nace en 0 y solo cambia por transacciones (el saldo inicial es un "Depósito de apertura"). Siempre se cumple: saldo = depósitos + transferencias recibidas − retiros − transferencias enviadas.
- **CHECK como primera defensa** y **triggers como segunda** (reglas entre tablas o bases).
- **Referencias distribuidas sin FOREIGN KEY** (SQL Server no las permite entre bases): integridad por triggers en ambos sentidos.
- **Auditoría genérica en JSON**: una sola tabla guarda la imagen anterior y posterior de cualquier fila.
- **Índices** sobre FKs y sobre `(id_cuenta, fecha)` en Transacciones.

---

## 9. Funcionamiento del sistema paso a paso

### 9.1 Registrar un cliente
```sql
EXEC dbo.sp_Cliente_Insertar @nombre = N'Ana Gómez', @documento = '123', @tipo_cliente = 'NATURAL';
```
1. Valida datos obligatorios, tipo de cliente y documento no repetido (si falla → `THROW`).
2. Inserta el cliente como ACTIVO.
3. `tr_Clientes_Auditoria` registra el INSERT en `BancoRemoto.dbo.Auditoria`.

### 9.2 Abrir una cuenta
```sql
EXEC dbo.sp_Cuenta_Insertar @numero_cuenta = 'AH-0100', @id_cliente = 1,
     @id_tipo_cuenta = 1, @id_sucursal = 2, @saldo_inicial = 500000;
```
1. Valida saldo inicial no negativo, número único y cliente ACTIVO.
2. **Consulta distribuida**: verifica en `SRV_REMOTO` el tipo de cuenta y la sucursal.
3. En una transacción: inserta la cuenta con saldo 0 y un DEPÓSITO "Depósito de apertura".
4. `tr_Cuentas_Integridad` revalida contra la base remota y exige saldo inicial 0.
5. `tr_Transacciones_ActualizarSaldo` suma el depósito. COMMIT: todo o nada.

### 9.3 Depósito, retiro y transferencia
```sql
EXEC dbo.sp_Transaccion_Insertar @id_cuenta = 1, @tipo = 'RETIRO', @monto = 200000;
EXEC dbo.sp_Transaccion_Insertar @id_cuenta = 1, @tipo = 'TRANSFERENCIA', @monto = 300000, @id_cuenta_destino = 3;
```
1. Valida tipo, monto > 0 y, si es transferencia, destino distinto.
2. Bloquea la cuenta (`WITH (UPDLOCK, ROWLOCK)`) para evitar dos retiros simultáneos sobre el mismo saldo.
3. Verifica cuentas ACTIVAS.
4. **No permitir saldo negativo**: retiro con `saldo − monto < 0` → error 50030.
5. **No permitir transferencias sin fondos**: `saldo < monto` → error 50029.
6. Inserta; el trigger aplica el efecto (depósito +, retiro −, transferencia − origen / + destino), revalida fondos y actualiza saldos.
7. Se audita la transacción y cada cambio de saldo.

> La validación de fondos tiene tres capas: procedimiento (mensaje claro), trigger (protege inserciones directas) y `CHECK (saldo >= 0)`.

### 9.4 Anular una transacción
`sp_Transaccion_Eliminar` borra la transacción y el trigger aplica el efecto inverso. Si al revertir un saldo quedaría negativo, se rechaza. Solo la descripción es editable (`sp_Transaccion_Actualizar`).

### 9.5 Otorgar un préstamo
```sql
EXEC dbo.sp_Prestamo_Insertar @id_cliente = 12, @monto = 4000000, @plazo = 12, @id_producto = 1;
```
1. Valida cliente ACTIVO, monto > 0 y plazo 1–360.
2. **Consulta distribuida**: toma del producto remoto la tasa (debe ser CREDITO y activo).
3. `tr_Prestamos_Integridad` valida y calcula `saldo_pendiente = fn_CalcularTotalPrestamo(...)`. Ej.: 4.000.000 al 18 % por 12 meses = **4.720.000**.

### 9.6 Registrar un pago
```sql
EXEC dbo.sp_Pago_Insertar @id_prestamo = 1, @monto = 566667;
```
1. Valida préstamo ACTIVO/MORA y pago ≤ saldo pendiente.
2. `tr_Pagos_ActualizarPrestamo` descuenta el saldo; si llega a 0 → **PAGADO**.
3. Si un pago se anula o corrige, se ajusta la diferencia y un préstamo PAGADO vuelve a ACTIVO.

### 9.7 Cerrar una cuenta / eliminar un cliente
- `sp_Cuenta_Eliminar` → trigger `INSTEAD OF`: con saldo → error; con movimientos → CERRADA; sin movimientos → borrado físico.
- `sp_Cliente_Eliminar` → con cuentas abiertas o préstamos vigentes → error; con historial → INACTIVO; sin historial → borrado físico.

### 9.8 Administración de sedes desde la sede central
- `sp_Dist_ResumenSedes`: empleados (remoto) + clientes, cuentas y saldos (local) por sede.
- `sp_Dist_RegistrarEmpleado`: ejecuta por RPC `sp_Empleado_Insertar` en el remoto.
- CRUD remoto: `EXEC SRV_REMOTO.BancoRemoto.dbo.sp_Sucursal_Insertar ...`, `sp_TipoCuenta_*`, `sp_Empleado_*`.
- `sp_Dist_ConsultarAuditoria`: historial remoto filtrado por tabla y fechas.

---

## 10. Triggers

21 triggers, al menos uno por tabla. Garantizan las reglas **siempre**, sin importar desde dónde se haga el cambio.

| Tabla | Trigger | Tipo | Función |
|---|---|---|---|
| Clientes | `tr_Clientes_Auditoria` | AFTER I/U/D | Auditoría remota. |
| | `tr_Clientes_ControlEliminacion` | INSTEAD OF DELETE | No borrar con productos vigentes; borrado lógico si tiene historial. |
| | `tr_Clientes_ValidarInactivacion` | AFTER UPDATE | No inactivar clientes con productos vigentes. |
| Cuentas | `tr_Cuentas_Auditoria` | AFTER I/U/D | Auditoría. |
| | `tr_Cuentas_Integridad` | AFTER I/U | **Integridad distribuida** (tipo y sucursal existen en el remoto); cliente activo; nace con saldo 0; saldo no editable a mano (`TRIGGER_NESTLEVEL()`); no cerrar con dinero. |
| | `tr_Cuentas_EvitarEliminacionConSaldo` | INSTEAD OF DELETE | **Requisito:** evita eliminar cuentas con saldo; cierre lógico o borrado físico. |
| Transacciones | `tr_Transacciones_ActualizarSaldo` | AFTER I/U/D | **Requisito:** actualiza el saldo automáticamente (por conjuntos, soporta INSERT múltiple); valida fondos; transacciones inmutables. |
| | `tr_Transacciones_Auditoria` | AFTER I/U/D | Auditoría. |
| Prestamos | `tr_Prestamos_Integridad` | AFTER I/U | **Requisito (integridad):** cliente activo; producto remoto de crédito; nace ACTIVO; máx. 3 vigentes; sin cambios financieros si hay pagos; saldo no editable; calcula saldo; PAGADO ⇔ saldo 0. |
| | `tr_Prestamos_ControlEliminacion` | INSTEAD OF DELETE | No borrar préstamos con pagos. |
| | `tr_Prestamos_Auditoria` | AFTER I/U/D | Auditoría. |
| Pagos | `tr_Pagos_ActualizarPrestamo` | AFTER I/U/D | Descuenta/restituye saldo; no pagar de más ni préstamos no vigentes; marca PAGADO. |
| | `tr_Pagos_Auditoria` | AFTER I/U/D | Auditoría. |
| TiposCuenta | `tr_TiposCuenta_Auditoria` | AFTER I/U/D | Auditoría. |
| | `tr_TiposCuenta_EvitarEliminacion` | AFTER DELETE | No borrar tipos usados en BancoCentral. |
| Sucursales | `tr_Sucursales_Auditoria` | AFTER I/U/D | Auditoría. |
| | `tr_Sucursales_Control` | INSTEAD OF DELETE | No borrar la sede central ni sucursales con empleados o cuentas. |
| Empleados | `tr_Empleados_Auditoria` | AFTER I/U/D | Auditoría. |
| ProductosFinancieros | `tr_Productos_Auditoria` | AFTER I/U/D | Auditoría. |
| | `tr_Productos_EvitarEliminacion` | AFTER DELETE | No borrar productos usados por préstamos. |
| Auditoria | `tr_Auditoria_Inmutable` | INSTEAD OF U/D | Historial de solo lectura. |

### Cadena de triggers en una transferencia

```
INSERT Transacciones (TRANSFERENCIA 300.000 de cuenta 1 a cuenta 3)
  └─► tr_Transacciones_ActualizarSaldo   (nivel 1)
        ├─ valida cuentas ACTIVAS y fondos
        └─ UPDATE Cuentas (−300.000 en 1, +300.000 en 3)
              ├─► tr_Cuentas_Integridad  (nivel 2: cambio de saldo legítimo)
              └─► tr_Cuentas_Auditoria   → 2 filas en BancoRemoto.Auditoria
  └─► tr_Transacciones_Auditoria         → 1 fila en BancoRemoto.Auditoria
Si cualquier paso lanza THROW, se deshace TODO.
```

### Manejo de errores

Dentro de un trigger `XACT_ABORT` está activo: un `THROW` deshace la sentencia y todos sus efectos en cascada. Los procedimientos capturan el error en `CATCH`, hacen `ROLLBACK` si hay transacción abierta y lo re-lanzan con `THROW;`.

| Rango | Origen |
|---|---|
| 50001 – 50099 | Validaciones de procedimientos de BancoCentral |
| 50101 – 50599 | Triggers de BancoCentral (501xx clientes, 502xx cuentas, 503xx transacciones, 504xx préstamos, 505xx pagos) |
| 51001 – 51399 | Triggers y procedimientos de BancoRemoto |

---

## 11. Procedimientos almacenados

| Entidad | Insertar | Consultar | Actualizar | Eliminar |
|---|---|---|---|---|
| Clientes | `sp_Cliente_Insertar` | `sp_Cliente_Consultar` | `sp_Cliente_Actualizar` | `sp_Cliente_Eliminar` |
| Cuentas | `sp_Cuenta_Insertar` ★ | `sp_Cuenta_Consultar` ★ | `sp_Cuenta_Actualizar` ★ | `sp_Cuenta_Eliminar` |
| Transacciones | `sp_Transaccion_Insertar` | `sp_Transaccion_Consultar` | `sp_Transaccion_Actualizar` | `sp_Transaccion_Eliminar` |
| Préstamos | `sp_Prestamo_Insertar` ★ | `sp_Prestamo_Consultar` ★ | `sp_Prestamo_Actualizar` | `sp_Prestamo_Eliminar` |
| Pagos | `sp_Pago_Insertar` | `sp_Pago_Consultar` | `sp_Pago_Actualizar` | `sp_Pago_Eliminar` |
| Tipos de cuenta (remoto) | `sp_TipoCuenta_Insertar` | `sp_TipoCuenta_Consultar` | `sp_TipoCuenta_Actualizar` | `sp_TipoCuenta_Eliminar` |
| Sucursales (remoto) | `sp_Sucursal_Insertar` | `sp_Sucursal_Consultar` | `sp_Sucursal_Actualizar` | `sp_Sucursal_Eliminar` |
| Empleados (remoto) | `sp_Empleado_Insertar` | `sp_Empleado_Consultar` | `sp_Empleado_Actualizar` | `sp_Empleado_Eliminar` |

★ Acceden al Linked Server. Distribuidos adicionales: `sp_Dist_CuentasPorSucursal`, `sp_Dist_ClientesSucursalTipoCuenta`, `sp_Dist_ResumenSedes`, `sp_Dist_RegistrarEmpleado` (RPC) y `sp_Dist_ConsultarAuditoria` → **10 procedimientos con acceso distribuido**.

Patrón común:

```sql
CREATE OR ALTER PROCEDURE dbo.sp_X
AS
BEGIN
    SET NOCOUNT ON;
    BEGIN TRY
        -- 1. validaciones  -> THROW 500xx, 'mensaje', 1;
        -- 2. BEGIN TRANSACTION (si hay varias sentencias)
        -- 3. operación (los triggers completan la lógica)
        -- 4. COMMIT y mensaje de resultado
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;   -- re-lanza el error original
    END CATCH
END;
```

---

## 12. Vistas

| Vista | Propósito |
|---|---|
| `vw_ClientesRegistradosActuales` | Clientes ACTIVOS con cuentas abiertas, préstamos vigentes y saldo total. |
| `vw_PrestamosDetalladoPorCliente` | Préstamos con cliente, producto, capital, tasa, plazo, total, cuota, pagado, saldo y % pagado. |
| `vw_PagosPorCliente` | Cada pago con cliente, préstamo y acumulado (`SUM() OVER`). |
| `vw_CuentasActivas` | Cuentas ACTIVAS con cliente, tipo y sucursal. |
| `vw_Distribuida_CuentasSucursalTipo` | **Distribuida**: cuentas locales + tipos y sucursales vía `SRV_REMOTO`. |
| `vw_Distribuida_EmpleadosPorSede` | Distribuida con `OPENQUERY`: empleados por sede. |

---

## 13. Funciones definidas por el usuario

| Función | Tipo | Lógica |
|---|---|---|
| `fn_CalcularTotalPrestamo` | Escalar | `ROUND(monto × (1 + interés/100 × plazo/12), 2)` |
| `fn_SaldoTotalCliente` | Escalar | `SUM(saldo)` de cuentas no cerradas; 0 si no tiene. |
| `fn_ResumenFinancieroCliente` | Tabla | Cuentas, saldo, préstamos, monto prestado, pagado, deuda activa y patrimonio neto. `NULL` = todos. Dos `CROSS APPLY` para agregar sin multiplicar filas. |
| `fn_CuentasConMasDeNTransacciones` | Tabla | Movimientos por cuenta en un periodo (incluye transferencias recibidas) con `HAVING COUNT(*) > N`. |
| `fn_DetectarAnomaliasRetiros` | Tabla | Ventanas deslizantes de tiempo por auto-join. |
| `fn_ClientesConProductosYSaldoMayorA` | Tabla | Reutiliza el resumen y filtra cuentas activas, préstamos vigentes y saldo > valor. |

---

## 14. Consultas complejas

| # | Consulta | Técnica |
|---|---|---|
| 1 | Saldo total por cliente | `LEFT JOIN` (incluye clientes sin cuentas), excluye cerradas, `GROUP BY` + `SUM`. |
| 2 | Promedio de saldo por tipo de cuenta | **Distribuida**: `SRV_REMOTO…TiposCuenta` LEFT JOIN Cuentas; AVG, MIN, MAX. |
| 3 | Clientes con préstamos activos | JOIN con estado ACTIVO/MORA; `SUM(CASE…)` para mora. |
| 4 | Cuentas por sucursal | **Distribuida**: sucursales remotas LEFT JOIN cuentas; también `sp_Dist_CuentasPorSucursal`. |
| 5 | Transacciones de un cliente por rango de fechas | `sp_TransaccionesClienteRangoFechas`: origen **o** destino del cliente; clasifica ENTRADA / SALIDA / ENTRE CUENTAS PROPIAS; rango `>= inicio AND < fin + 1 día`. |
| 6 | Resumen financiero | `fn_ResumenFinancieroCliente`. |
| 7 | Top 5 por saldo | `TOP (5) WITH TIES` + `RANK() OVER`. |
| 8 | Mayor deuda activa | `TOP (1) WITH TIES` sobre el resumen. |
| 9 | Ingresos por intereses | CTE; interés proyectado = total − capital; cobrado = pagado × interés / total; `GROUPING SETS` para TOTAL GENERAL. |
| 10 | Cuentas con más de N transacciones | `fn_CuentasConMasDeNTransacciones(N, desde, hasta)`. |
| 11 | Anomalías (muchos retiros en poco tiempo) | `fn_DetectarAnomaliasRetiros(3, 60)`: ventana de 60 min por retiro y auto-join; detecta `AH-0009` (5 retiros en 24 min, 15/10/2026). Riesgo ALTO si duplica el umbral. |
| 12 | Clientes + sucursal + tipo de cuenta | **Distribuida** en 3 versiones: 4 partes, `OPENQUERY` en procedimiento (filtro por ciudad) y vista. |
| 13 | Cuentas activas + préstamos activos + saldo > valor | `fn_ClientesConProductosYSaldoMayorA(valor)`. |
| 14 | Flujo neto por cliente | CTE con `UNION ALL` de movimientos y transferencias recibidas; `CROSS APPLY` + `SUM(CASE…)`; flujo efectivo = depósitos − retiros; flujo total incluye transferencias; tendencia ahorra/desahorra. |

---

## 15. Evidencias para la entrega

| # | Evidencia | Dónde |
|---|---|---|
| 1 | Linked Server en el Explorador de objetos y en `sys.servers` | Script 03 / Parte 1 del 10 |
| 2 | `sp_testlinkedserver`, consulta de 4 partes y `OPENQUERY` | Script 03 |
| 3 | Consulta de acceso distribuido | Parte 1 del 10; consultas 2, 4, 12 |
| 4 | CRUD de cada entidad | Partes 2 a 7 del 10 |
| 5 | Retiro sin saldo y transferencia sin fondos rechazados | Parte 4 del 10 |
| 6 | Triggers obligatorios | Partes 3, 4 y 5 del 10 |
| 7 | Procedimientos distribuidos y RPC | Parte 7 del 10 |
| 8 | 14 consultas y 6 vistas | Script 09 |
| 9 | Auditoría consultada desde la sede central | Parte 9 del 10 |

---

## 16. Despliegue opcional en dos servidores reales

1. Instalar otra instancia (ej. `MIEQUIPO\REMOTO`) u otro equipo y ejecutar allí `01_BD_Remota.sql`.
2. En la principal ejecutar `02`, y en el `03` cambiar `@datasrc` por el servidor remoto.
3. Recrear los sinónimos de BancoCentral con 4 partes:
   ```sql
   DROP SYNONYM dbo.syn_Auditoria;
   CREATE SYNONYM dbo.syn_Auditoria FOR SRV_REMOTO.BancoRemoto.dbo.Auditoria;
   ```
4. Crear en el remoto un Linked Server de regreso y ajustar `syn_CuentasCentral` y `syn_PrestamosCentral`.
5. Habilitar **MSDTC** en ambos equipos.

No se modifica ningún trigger, procedimiento ni vista.

---

## 17. Lista de verificación del enunciado

| Requisito | Cumplimiento |
|---|---|
| Base principal: Clientes, Cuentas, Transacciones, Préstamos, Pagos | ✅ BancoCentral (script 02) |
| Base remota: Tipos de cuenta, Sucursales, Empleados, Productos, Auditoría | ✅ BancoRemoto (script 01) |
| Sedes Medellín (central), Bogotá, Cartagena, San Andrés, Cali | ✅ Sucursales + índice único de sede central |
| Linked Server | ✅ `SRV_REMOTO` (script 03) |
| Consulta de acceso distribuido en la sede principal | ✅ Consultas 2, 4, 12 y vistas distribuidas |
| CRUD por entidad con `TRY...CATCH` | ✅ 32 procedimientos CRUD (20 + 12 remotos) |
| No permitir saldo negativo ni transferencias sin fondos | ✅ Procedimiento + trigger + CHECK |
| Mínimo 3 procedimientos distribuidos | ✅ 10 |
| Un trigger por tabla, incluidos los 3 obligatorios | ✅ 21 triggers en 10 tablas |
| 5 vistas | ✅ 6 (2 distribuidas) |
| 2 funciones escalares y 4 de tabla | ✅ Script 04 |
| 14 consultas | ✅ Script 09 |
