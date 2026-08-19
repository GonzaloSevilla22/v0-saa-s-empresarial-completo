## ADDED Requirements

### Requirement: Catálogo de formas de pago por cuenta

El sistema SHALL persistir un catálogo plano de formas de pago en la tabla `payment_methods` (`id` UUID PK, `account_id` UUID FK `accounts` NOT NULL, `name` TEXT NOT NULL, `kind` TEXT NOT NULL, `is_active` BOOLEAN NOT NULL DEFAULT TRUE, `sort_order` INTEGER NOT NULL DEFAULT 0, `created_at` TIMESTAMPTZ NOT NULL DEFAULT now(), `deleted_at` TIMESTAMPTZ NULL, `deleted_by` UUID NULL). El catálogo SHALL ser **plano** (sin jerarquías) y editable por el usuario en su `name`. El sistema SHALL impedir nombres duplicados dentro de una misma cuenta de forma case-insensitive sobre las filas vivas (`UNIQUE(account_id, lower(name)) WHERE deleted_at IS NULL`). La tabla SHALL tener RLS por `account_id` con tenancy account-direct, igual que `cost_centers`.

#### Scenario: Crear una forma de pago

- **WHEN** un `owner`/`admin` crea una forma de pago con un nombre válido y un `kind` del vocabulario cerrado
- **THEN** se persiste una fila en `payment_methods` con el `account_id` de su cuenta, `is_active = true` y `deleted_at = NULL`

#### Scenario: Nombre duplicado en la misma cuenta es rechazado

- **GIVEN** una cuenta que ya tiene una forma de pago viva "Mercado Pago"
- **WHEN** se intenta crear otra "mercado pago" en la misma cuenta
- **THEN** la operación es rechazada por el unique case-insensitive

#### Scenario: Aislamiento por cuenta

- **GIVEN** formas de pago de la cuenta A y de la cuenta B
- **WHEN** un usuario de la cuenta A lista las formas de pago
- **THEN** sólo ve las de la cuenta A

### Requirement: Vocabulario cerrado de `kind` compatible con las taxonomías existentes

El sistema SHALL restringir `payment_methods.kind` por CHECK al conjunto `{cash, transfer, card, check, wallet, credit, other}`. El `name` SHALL ser la etiqueta que ve y edita el usuario; el `kind` SHALL ser lo único que consuman los subsistemas para razonar sobre la forma de pago. El vocabulario SHALL ser un **superset de las dos taxonomías ya vivas** —el CHECK de `sales_orders.payment_method` (`{cash, transfer, card, other, credit}`) y la de las RPCs de cobro/pago (`{cash, transfer, card, check}`)— y este change NO SHALL modificar ninguna de las dos.

#### Scenario: `kind` fuera del vocabulario es rechazado

- **WHEN** se intenta persistir una forma de pago con `kind = 'crypto'`
- **THEN** la escritura es rechazada por el CHECK

#### Scenario: Renombrar no cambia la semántica

- **GIVEN** la forma de pago sembrada "Transferencia bancaria" con `kind = 'transfer'`
- **WHEN** el usuario la renombra a "Banco Nación"
- **THEN** el `kind` sigue siendo `transfer` y todo consumidor que agrupa por `kind` la sigue tratando como transferencia

### Requirement: Seed de formas de pago en el provisioning de la cuenta

El sistema SHALL sembrar seis formas de pago al crear una cuenta —Efectivo (`cash`), Transferencia bancaria (`transfer`), Tarjeta (`card`), Billetera virtual (`wallet`), Cuenta corriente (`credit`) y Otro (`other`)— de modo que un tenant nuevo pueda imputar la forma de pago sin configuración manual. El seed SHALL ejecutarse dentro de `handle_new_user` envuelto de forma que un fallo suyo **NUNCA** aborte el signup (degrada con warning), SHALL ser idempotente, y SHALL aplicarse por backfill a las cuentas ya existentes.

#### Scenario: Cuenta nueva nace con el catálogo sembrado

- **WHEN** se registra un usuario nuevo y se provisiona su cuenta
- **THEN** la cuenta tiene las seis formas de pago activas, sin intervención manual

#### Scenario: El seed no puede romper el registro

- **GIVEN** una condición que hace fallar el sub-bloque de seed de formas de pago
- **WHEN** se registra un usuario nuevo
- **THEN** el perfil, la cuenta y la membresía se crean igual y el fallo del seed sólo deja un warning

#### Scenario: Re-ejecución idempotente

- **GIVEN** una cuenta que ya tiene el catálogo sembrado
- **WHEN** el backfill vuelve a ejecutarse
- **THEN** no se duplica ninguna forma de pago

### Requirement: Gestión del catálogo gateada por rol

El sistema SHALL permitir a cualquier miembro de la cuenta **leer** el catálogo de formas de pago, y SHALL restringir crear, renombrar, reordenar, desactivar y eliminar a los roles `owner` y `admin`.

#### Scenario: Member puede leer pero no escribir

- **GIVEN** un usuario con rol `member`
- **WHEN** lista las formas de pago de su cuenta
- **THEN** la lectura es permitida
- **AND** **WHEN** intenta crear o editar una forma de pago
- **THEN** la operación es rechazada con 403

#### Scenario: Owner/admin gestiona el catálogo

- **GIVEN** un usuario con rol `owner` o `admin`
- **WHEN** crea, renombra o desactiva una forma de pago de su cuenta
- **THEN** la operación es permitida y persiste

### Requirement: La baja es desactivación y preserva la imputación histórica

El sistema SHALL tratar la baja de una forma de pago como desactivación (`is_active = false`) o soft delete (`deleted_at`/`deleted_by`), y NO SHALL borrar físicamente una fila referenciada por operaciones. Las operaciones ya imputadas SHALL conservar su `payment_method_id` y su nombre histórico. Una forma de pago dada de baja NO SHALL aparecer en los selectores de altas nuevas, pero SÍ SHALL seguir apareciendo en los listados y en el reporte de los períodos en que se usó.

#### Scenario: Desactivar una forma de pago en uso

- **GIVEN** la forma de pago "Cheque" con ventas ya imputadas
- **WHEN** un `owner`/`admin` la desactiva
- **THEN** deja de ofrecerse en el selector de altas nuevas
- **AND** las ventas históricas conservan su `payment_method_id`

#### Scenario: Una forma de pago inactiva sigue apareciendo en el reporte

- **GIVEN** la forma de pago "Cheque" desactivada, con $8.000 de ventas imputadas dentro del rango consultado
- **WHEN** se ejecuta el reporte de distribución por forma de pago sobre ese rango
- **THEN** la fila "Cheque" aparece con su total y su nombre histórico

### Requirement: Imputación opcional de la forma de pago en ventas

El sistema SHALL permitir imputar opcionalmente una venta a una forma de pago mediante una columna nullable `payment_method_id` (FK a `payment_methods`, `ON DELETE SET NULL`) en `public.sales`. En una venta multi-línea (varias filas `sales` con el mismo `operation_id`), la forma de pago SHALL ser **por operación**: todas las líneas de la operación comparten el mismo `payment_method_id`. El alta de venta (`rpc_create_sale_operation`) SHALL aceptar un `payment_method_id` opcional, validar que pertenezca a la cuenta y esté viva (igual que valida `branch_id`), y persistirlo en todas las líneas. La firma de idempotencia de la venta NO SHALL cambiar, y la RPC MUST preservar sin alteración el acarreo de líneas a `sale_items` y la escritura de `stock_movements`.

#### Scenario: Alta de venta con forma de pago

- **WHEN** se crea una venta de dos líneas con una `payment_method_id` activa de la cuenta
- **THEN** las dos filas de `sales` de esa operación quedan con ese `payment_method_id`

#### Scenario: Alta de venta sin forma de pago

- **WHEN** se crea una venta sin informar forma de pago
- **THEN** la venta se persiste con `payment_method_id = NULL` y se muestra como "Sin especificar"

#### Scenario: Forma de pago de otra cuenta es rechazada

- **WHEN** se crea una venta informando una `payment_method_id` que pertenece a otra cuenta
- **THEN** la operación es rechazada y no se persiste ninguna línea

### Requirement: Imputación opcional de la forma de pago en compras

El sistema SHALL permitir imputar opcionalmente una compra a una forma de pago mediante una columna nullable `payment_method_id` (FK a `payment_methods`, `ON DELETE SET NULL`) en `public.purchases`, con la misma semántica por operación que en ventas. El alta de compra (`rpc_create_purchase_operation`) SHALL aceptar un `payment_method_id` opcional, validar que pertenezca a la cuenta y persistirlo en todas las líneas, sin alterar la imputación a centro de costo ni el comportamiento de stock/ledger ya especificados.

#### Scenario: Alta de compra con forma de pago y centro de costo

- **WHEN** se crea una compra informando `payment_method_id` y `cost_center_id`
- **THEN** todas las líneas de la operación quedan con ambos valores, cada uno en su columna

#### Scenario: Compra sin forma de pago

- **WHEN** se crea una compra sin informar forma de pago
- **THEN** la compra se persiste con `payment_method_id = NULL`

### Requirement: La edición de una operación preserva la forma de pago

El sistema SHALL permitir cambiar la forma de pago de una operación existente desde el editor, y SHALL **preservar** el `payment_method_id` vigente cuando la edición no informa una forma de pago. Las RPCs de edición (`rpc_atomic_update_sale_operation`, `rpc_atomic_update_purchase_operation`) SHALL propagar el valor resultante a todas las líneas de la operación, incluidas las líneas agregadas en esa misma edición, sin alterar el acarreo de líneas ni la reversa/aplicación de stock.

#### Scenario: Editar una venta sin tocar la forma de pago

- **GIVEN** una venta imputada a "Efectivo"
- **WHEN** se edita cambiando cantidades y agregando una línea, sin informar forma de pago
- **THEN** todas las líneas resultantes —la nueva incluida— siguen imputadas a "Efectivo"

#### Scenario: Cambiar la forma de pago de una operación

- **GIVEN** una compra imputada a "Efectivo"
- **WHEN** se edita informando la forma de pago "Transferencia bancaria"
- **THEN** todas las líneas de la operación quedan imputadas a "Transferencia bancaria"

### Requirement: La forma de pago es una etiqueta y no dispara asientos, caja ni cuenta corriente

El sistema NO SHALL derivar de `sales.payment_method_id` / `purchases.payment_method_id` ningún efecto automático sobre otros subsistemas: elegir una forma de pago de `kind = 'cash'` NO SHALL exigir sesión de caja abierta ni generar `cash_movements`; `kind = 'credit'` NO SHALL generar cargo en `customer_account_movements` ni en cuentas de proveedor; `kind = 'transfer'`/`card` NO SHALL generar `bank_movements` ni asiento. Las superficies que ofrecen el selector SHALL declarar explícitamente esa limitación al usuario, de forma que la etiqueta no se lea como una afordancia que el sistema no cumple.

#### Scenario: Venta a cuenta corriente desde el form de venta

- **WHEN** se registra una venta con la forma de pago de `kind = 'credit'`
- **THEN** la venta queda imputada a esa forma de pago
- **AND** no se crea ningún movimiento en `customer_account_movements`
- **AND** el form informa al usuario dónde se registra el cargo en la cuenta corriente

#### Scenario: Venta en efectivo fuera del POS no exige caja abierta

- **GIVEN** una cuenta sin sesión de caja abierta
- **WHEN** se registra una venta con la forma de pago de `kind = 'cash'` desde el form de venta
- **THEN** la venta se registra normalmente y no se crea ningún `cash_movement`

### Requirement: Lectura de la forma de pago en operaciones nacidas en el POS

El sistema SHALL mostrar una forma de pago para las operaciones de venta originadas en el POS derivándola **de lectura** desde el texto legacy de su `sales_orders.payment_method` mapeado por `kind` (`cash` → la forma de pago de `kind = 'cash'` de la cuenta; `other` → la de `kind = 'other'`). Esta derivación NO SHALL escribir en `sales`, `sales_orders` ni `payment_methods`, y este change NO SHALL modificar `rpc_quick_sale`, `rpc_confirm_sales_order` ni el CHECK de `sales_orders.payment_method`.

#### Scenario: Venta del POS en efectivo listada con su forma de pago

- **GIVEN** una venta creada en el POS cuya orden tiene `payment_method = 'cash'` y cuyas filas de `sales` tienen `payment_method_id = NULL`
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación se muestra con la forma de pago "Efectivo"
- **AND** ninguna fila de `sales` es modificada por la lectura

#### Scenario: La imputación explícita gana sobre la derivación

- **GIVEN** una operación con `payment_method_id` persistido
- **WHEN** se lista
- **THEN** se muestra la forma de pago persistida, sin consultar el texto legacy de la orden

### Requirement: Read-model de distribución por forma de pago

El sistema SHALL exponer `rpc_payment_method_report(p_account_id, p_start, p_end)` que agregue, por forma de pago y para el rango pedido, el total vendido y el total comprado, con una fila propia para las operaciones sin imputar ("Sin especificar"). El RPC SHALL ser `SECURITY DEFINER` con `search_path` fijo y SHALL verificar la membresía del caller sobre `p_account_id` (P0401), espejando `rpc_cost_center_report`. SHALL cumplir los invariantes RN-D: importe de línea con `COALESCE(total, amount)`, conteo de operaciones con `COUNT(DISTINCT COALESCE(operation_id, id))`, bordes `date >= p_start AND date < (p_end + 1)`, y todo importe de salida `NUMERIC`. **Excepción documentada a RN-D1**: el reporte NO SHALL restar notas de crédito, porque una NC no tiene forma de pago atribuible; la excepción SHALL estar visible en la propia pantalla del reporte, igual que la ya documentada para el margen por canal.

#### Scenario: Agregación por forma de pago

- **GIVEN** en el rango: dos ventas en "Efectivo" por $10.000 y $5.000, una en "Transferencia bancaria" por $20.000 y una compra en "Efectivo" por $3.000
- **WHEN** se ejecuta el reporte sobre ese rango
- **THEN** "Efectivo" muestra $15.000 vendidos y $3.000 comprados, y "Transferencia bancaria" $20.000 vendidos

#### Scenario: Operaciones sin imputar

- **GIVEN** ventas históricas con `payment_method_id = NULL` dentro del rango
- **WHEN** se ejecuta el reporte
- **THEN** aparecen agrupadas en una fila "Sin especificar" y no se reparten entre las demás formas de pago

#### Scenario: Caller de otra cuenta

- **WHEN** un usuario que no es miembro de `p_account_id` ejecuta el reporte
- **THEN** la llamada es rechazada con P0401

### Requirement: Superficies de la forma de pago

El sistema SHALL exponer la forma de pago en: (a) el gestor del catálogo dentro de `/configuracion`, junto al de centros de costo, visible sólo para `owner`/`admin`; (b) un selector "Forma de pago" en el alta y edición de ventas y de compras, que ofrece sólo las formas activas; (c) un badge con la forma de pago y un filtro por forma de pago en los listados de ventas y de compras; y (d) la pantalla `/reportes/formas-pago`, alcanzable desde una entrada propia del sidebar y sin gate de plan —mismo criterio que el reporte de centros de costo, porque gatearlo dejaría al plan free imputando datos que no puede leer. Toda superficie nueva SHALL usar los tokens semánticos y los componentes base del design system, y SHALL verificarse en desktop y mobile y en tema claro y oscuro.

#### Scenario: Alta de venta con el selector

- **WHEN** un usuario abre el form de venta
- **THEN** ve el selector "Forma de pago" con las formas activas de su cuenta y la opción de dejarlo sin especificar

#### Scenario: Filtrar el listado por forma de pago

- **GIVEN** operaciones imputadas a distintas formas de pago
- **WHEN** el usuario filtra el listado por "Efectivo"
- **THEN** sólo ve las operaciones imputadas a "Efectivo"

#### Scenario: El member no ve el gestor del catálogo

- **GIVEN** un usuario con rol `member`
- **WHEN** abre `/configuracion`
- **THEN** no se le ofrece la gestión del catálogo de formas de pago, aunque sí puede elegir formas de pago al operar

### Requirement: Endpoints de formas de pago en el backend

El sistema SHALL exponer el catálogo y el reporte a través del backend FastAPI en las tres capas (router → service → repository), con validación Pydantic v2 en el endpoint, guardas de rol en el service y errores en formato RFC 7807 según `api-standards`. El frontend NO SHALL escribir el catálogo directamente contra Supabase.

#### Scenario: Listar formas de pago activas

- **WHEN** el frontend pide el catálogo sin incluir inactivas
- **THEN** el backend devuelve sólo las formas vivas y activas de la cuenta del usuario autenticado

#### Scenario: Crear sin rol suficiente

- **WHEN** un `member` hace POST al endpoint de creación
- **THEN** el backend responde 403 en formato RFC 7807, sin tocar la base
