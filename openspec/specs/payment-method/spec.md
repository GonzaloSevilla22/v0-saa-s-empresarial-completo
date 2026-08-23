# payment-method Specification

> Synced from change `metodos-pago-operaciones` — 2026-08-19; updated from `pos-catalogo-pagos` — 2026-08-20 (el POS pasa a ofrecer el catálogo y a disparar efectos tipados por camino, en vez de una etiqueta pasiva)

## Purpose

Catálogo de formas de pago por cuenta (`payment_methods` + vocabulario cerrado `kind`), su seed automático de provisioning, la imputación **opcional** de la forma de pago en ventas y compras (alta y edición, por operación), las superficies que la hacen usable (gestor del catálogo, selectores, POS, badges, filtros) y el read-model de distribución por forma de pago (`rpc_payment_method_report`).

En el camino de los **formularios** (venta y compra) sigue siendo una **etiqueta**: elegirla ahí NO dispara por sí sola ningún movimiento de caja, cargo en cuenta corriente ni asiento contable. En el camino del **mostrador** (POS / `quickSale()` / confirmación de una orden de venta) pasa a ser el disparador **tipado**: `kind = 'cash'` mueve caja, `kind = 'credit'` postea el cargo en la cuenta corriente del cliente — la distinción es por camino, no por etiqueta (`pos-catalogo-pagos`, resuelve la regresión de C-30 documentada ahí).
## Requirements
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

El sistema SHALL restringir `payment_methods.kind` por CHECK al conjunto `{cash, transfer, card, check, wallet, credit, other}`, y ese CHECK SHALL ser el **único** lugar donde vive el vocabulario de formas de pago del sistema. El `name` SHALL ser la etiqueta que ve y edita el usuario; el `kind` SHALL ser lo único que consuman los subsistemas para razonar sobre la forma de pago. `sales_orders` NO SHALL tener una columna de texto con su propia copia del vocabulario: la forma de pago de una orden SHALL leerse siempre por `payment_method_id → payment_methods.kind`. El CHECK de las RPCs de cobro/pago (`{cash, transfer, card, check}`) sigue siendo un subconjunto propio, sin tocar.

#### Scenario: `kind` fuera del vocabulario es rechazado

- **WHEN** se intenta persistir una forma de pago con `kind = 'crypto'`
- **THEN** la escritura es rechazada por el CHECK

#### Scenario: Renombrar no cambia la semántica

- **GIVEN** la forma de pago sembrada "Transferencia bancaria" con `kind = 'transfer'`
- **WHEN** el usuario la renombra a "Banco Nación"
- **THEN** el `kind` sigue siendo `transfer` y todo consumidor que agrupa por `kind` la sigue tratando como transferencia

#### Scenario: El vocabulario tiene una sola definición

- **WHEN** se inspecciona el schema en busca de CHECKs que enumeren formas de pago
- **THEN** existe únicamente `payment_methods_kind_check` con los 7 valores, y no existe ningún `sales_orders_payment_method_check`

### Requirement: Seed de formas de pago en el provisioning de la cuenta

El sistema SHALL sembrar siete formas de pago al crear una cuenta —Efectivo (`cash`), Transferencia bancaria (`transfer`), Tarjeta (`card`), Billetera virtual (`wallet`), Cuenta corriente (`credit`), Otro (`other`) y **Cheque (`check`)**— de modo que un tenant nuevo pueda imputar la forma de pago sin configuración manual, incluyendo el `kind` `check` que el CHECK del vocabulario admite pero que el seed original (`metodos-pago-operaciones`) no sembraba (OQ-1: sin este 7º método, la resolución legacy de `sales-order` nunca imputaba una venta con cheque). El seed SHALL ejecutarse dentro de `handle_new_user` envuelto de forma que un fallo suyo **NUNCA** aborte el signup (degrada con warning), SHALL ser idempotente, y SHALL aplicarse por backfill a las cuentas ya existentes.

#### Scenario: Cuenta nueva nace con el catálogo sembrado

- **WHEN** se registra un usuario nuevo y se provisiona su cuenta
- **THEN** la cuenta tiene las siete formas de pago activas, sin intervención manual

#### Scenario: El seed no puede romper el registro

- **GIVEN** una condición que hace fallar el sub-bloque de seed de formas de pago
- **WHEN** se registra un usuario nuevo
- **THEN** el perfil, la cuenta y la membresía se crean igual y el fallo del seed sólo deja un warning

#### Scenario: Re-ejecución idempotente

- **GIVEN** una cuenta que ya tiene el catálogo sembrado
- **WHEN** el backfill vuelve a ejecutarse
- **THEN** no se duplica ninguna forma de pago

#### Scenario: Cuenta existente sin Cheque lo recibe por backfill

- **GIVEN** una cuenta sembrada antes de este change, con las 6 formas de pago originales y sin `kind = 'check'`
- **WHEN** se aplica la migración de `limpiezas-pagos-admin`
- **THEN** la cuenta queda con una 7ª forma de pago "Cheque" (`kind = 'check'`), activa, sin alterar las 6 existentes

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

El alta de compra SHALL aceptar además un `supplier_id` opcional como atributo **de operación**, validarlo contra la cuenta (existente y no borrado) y persistirlo en `public.purchases.supplier_id` en **todas** las líneas de la operación, incluidas las líneas sin producto. La forma de pago y el proveedor son ortogonales entre sí salvo en un caso: cuando el `kind` derivado de la forma de pago es `credit`, el proveedor pasa a ser obligatorio, según la capability `supplier-account`.

#### Scenario: Alta de compra con forma de pago y centro de costo

- **WHEN** se crea una compra informando `payment_method_id` y `cost_center_id`
- **THEN** todas las líneas de la operación quedan con ambos valores, cada uno en su columna

#### Scenario: Compra sin forma de pago

- **WHEN** se crea una compra sin informar forma de pago
- **THEN** la compra se persiste con `payment_method_id = NULL`

#### Scenario: Alta de compra con proveedor

- **WHEN** se crea una compra informando `supplier_id`
- **THEN** todas las líneas de la operación —con producto y sin producto— quedan con ese `supplier_id`

#### Scenario: Compra sin proveedor

- **WHEN** se crea una compra sin informar proveedor y sin una forma de pago de `kind = 'credit'`
- **THEN** la compra se persiste con `supplier_id = NULL`

### Requirement: La superficie de compra declara el efecto de la cuenta corriente antes de confirmar

El sistema SHALL declarar en el formulario de compra, antes de confirmar, qué va a ocurrir con la cuenta corriente del proveedor según la forma de pago elegida: al elegir una forma de pago de `kind = 'credit'` SHALL indicar que el importe se cargará a la cuenta del proveedor, exigir el proveedor y mostrar el saldo actual y el proyectado; al elegir cualquier otro `kind` NO SHALL prometer ningún efecto sobre la cuenta corriente. La ausencia de forma de pago imputada NO SHALL presentarse como equivalente a cuenta corriente, aunque el asiento contable la trate como tal por compatibilidad histórica.

#### Scenario: Elegir cuenta corriente explica el efecto

- **WHEN** el usuario elige en el formulario de compra una forma de pago de `kind = 'credit'`
- **THEN** la pantalla indica que la compra se cargará a la cuenta corriente del proveedor y muestra el saldo actual y el proyectado una vez elegido el proveedor

#### Scenario: Elegir cuenta corriente sin proveedor advierte y bloquea

- **WHEN** el usuario elige una forma de pago de `kind = 'credit'` sin proveedor seleccionado
- **THEN** la pantalla lo advierte y no permite confirmar la compra

#### Scenario: No elegir forma de pago no promete cuenta corriente

- **WHEN** el usuario no imputa ninguna forma de pago a la compra
- **THEN** la pantalla no anuncia ningún efecto sobre la cuenta corriente del proveedor, y la compra se registra sin cargo

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

### Requirement: La forma de pago dispara efectos según el camino, no según la etiqueta

El sistema SHALL determinar los efectos sobre caja y cuenta corriente por el **camino** que registra la operación combinado con el `kind` de la forma de pago, y SHALL derivar ese `kind` en el servidor a partir de `payment_method_id`, nunca aceptándolo como dato del cliente. En el camino del mostrador (POS / `quickSale` / confirmación de orden de venta) los efectos SHALL ser automáticos: `kind = 'cash'` exige sesión de caja abierta y genera `cash_movements`; `kind = 'credit'` exige cliente y postea el cargo en `customer_account_movements`. En el camino de los formularios de venta y de compra, `kind = 'credit'` SHALL exigir la parte identificada (cliente en venta, proveedor en compra) y postear el cargo en la cuenta corriente correspondiente, mientras que `kind = 'cash'` SHALL generar `cash_movements` **sólo** ante un opt-in explícito del usuario que cumpla las tres condiciones de servidor definidas en la capability `cash-session`. Los `kind` bancarios (`transfer`, `card`, `check`, `wallet`) SHALL generar un `bank_movement` en el ledger operativo —en todos los caminos de alta de venta y de compra— **únicamente** cuando se resuelva una cuenta bancaria destino según las reglas de la capability `bank-movement`; sin destino resuelto SHALL comportarse como etiqueta, que es el estado inicial de toda forma de pago sembrada. El `kind = 'other'` SHALL comportarse siempre como etiqueta a efectos de caja, cuenta corriente y banco. Nada de esto SHALL alterar la contrapartida contable que la capability `journal-entry` asigna a cada `kind`, que se sigue posteando de forma asíncrona por el outbox y es independiente del ledger operativo. Las superficies que ofrecen el selector SHALL declarar explícitamente qué efecto tiene cada elección, de forma que la etiqueta no se lea como una afordancia que el sistema no cumple ni oculte un efecto que sí produce.

#### Scenario: Venta en efectivo desde el form sin opt-in no mueve caja

- **GIVEN** una cuenta sin sesión de caja abierta
- **WHEN** se registra una venta con la forma de pago de `kind = 'cash'` desde el form de venta
- **THEN** la venta se registra normalmente, no se crea ningún `cash_movement` y no se ofrece el opt-in

#### Scenario: Venta en efectivo desde el form con opt-in mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal de la venta
- **WHEN** se registra hoy una venta con la forma de pago de `kind = 'cash'` desde el form marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `sale` por el total, en el mismo commit que el descuento de stock

#### Scenario: Venta en efectivo desde el POS sí mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se cobra desde el POS con la forma de pago de `kind = 'cash'`
- **THEN** se crea un `cash_movements` de tipo `sale` por el total, en el mismo commit que el descuento de stock

#### Scenario: Cuenta corriente en el form sí genera cargo

- **WHEN** se registra una venta desde el form con la forma de pago de `kind = 'credit'` y un cliente seleccionado
- **THEN** la venta queda imputada a esa forma de pago y se crea el cargo correspondiente en `customer_account_movements` en el mismo commit

#### Scenario: Cuenta corriente en el form sin cliente es rechazada

- **WHEN** se registra una venta desde el form con la forma de pago de `kind = 'credit'` sin cliente
- **THEN** la operación falla con `credit_requires_client` y no se registra ni la venta ni ningún cargo

#### Scenario: El kind se deriva en el servidor

- **WHEN** una solicitud informa un `payment_method_id` de `kind = 'transfer'` junto con un texto de forma de pago que dice `cash`
- **THEN** el servidor rechaza la incoherencia y no aplica los efectos de efectivo

#### Scenario: Forma de pago de transferencia con destino configurado genera movimiento bancario

- **GIVEN** una forma de pago de `kind = 'transfer'` con una cuenta bancaria activa configurada como destino
- **WHEN** se cobra desde el POS con esa forma de pago
- **THEN** la venta se confirma y se crea un `bank_movements` de ingreso contra esa cuenta, en el mismo commit

#### Scenario: Forma de pago de transferencia sin destino no genera movimiento bancario

- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'transfer'` sin destino bancario configurado y sin informar cuenta en la operación
- **THEN** la venta se confirma, no se crea ningún `bank_movements`, y la operación queda imputada a esa forma de pago

#### Scenario: El texto de apoyo nombra el efecto de cada elección

- **WHEN** el usuario elige en el form de venta una forma de pago de `kind = 'cash'`, de `kind = 'credit'` o de un `kind` bancario con destino configurado
- **THEN** la pantalla explica qué va a ocurrir con la caja, con la cuenta corriente del cliente o con la cuenta bancaria antes de confirmar

### Requirement: El POS ofrece el catálogo de formas de pago de la cuenta

El sistema SHALL ofrecer en el POS (`/ventas/pos`) las formas de pago **activas del catálogo de la cuenta**, ordenadas por `sort_order`, en lugar de un vocabulario fijo. El método preseleccionado SHALL ser el activo de `kind = 'cash'` con menor `sort_order` y, si la cuenta no tiene ninguno de ese `kind`, el primer activo por `sort_order`. Si la cuenta no tiene ninguna forma de pago activa, el POS SHALL seguir permitiendo cobrar por el camino legacy sin forma de pago imputada y SHALL mostrar un aviso con enlace al gestor del catálogo — degradar, nunca impedir el cobro. La grilla SHALL usar los tokens semánticos y componentes base del design system, con objetivos táctiles de al menos 44px, y SHALL verificarse en desktop y mobile y en tema claro y oscuro.

#### Scenario: El POS lista las formas de pago de la cuenta

- **GIVEN** una cuenta con las seis formas de pago sembradas y activas
- **WHEN** el usuario abre el POS
- **THEN** ve las seis opciones ordenadas por `sort_order`, con "Efectivo" preseleccionada

#### Scenario: Una forma de pago desactivada no se ofrece en el POS

- **GIVEN** una cuenta cuya forma de pago "Tarjeta" fue desactivada
- **WHEN** el usuario abre el POS
- **THEN** "Tarjeta" no aparece entre las opciones, y las ventas históricas imputadas a ella conservan su imputación

#### Scenario: Cuenta sin formas de pago activas sigue pudiendo cobrar

- **GIVEN** una cuenta que desactivó todas sus formas de pago
- **WHEN** el usuario carga un carrito y cobra desde el POS
- **THEN** la venta se confirma sin forma de pago imputada y la pantalla ofrece un enlace al gestor del catálogo

### Requirement: El POS exige cliente y muestra el saldo al cobrar a cuenta corriente

El sistema SHALL, cuando en el POS se elige una forma de pago de `kind = 'credit'`, exigir un cliente antes de permitir el cobro, mostrando el motivo en pantalla; SHALL mostrar el saldo actual de la cuenta corriente de ese cliente y el saldo proyectado tras la venta, reutilizando el read-model de cuenta corriente ya existente; y SHALL enlazar la cuenta corriente del cliente desde la confirmación de la venta. El bloqueo del cliente en la interfaz SHALL ser una comodidad, no la fuente de verdad: el rechazo definitivo SHALL provenir del backend.

#### Scenario: Cobrar a cuenta corriente sin cliente está bloqueado

- **GIVEN** un carrito con productos y la forma de pago de `kind = 'credit'` elegida
- **WHEN** el usuario no seleccionó cliente
- **THEN** el botón de cobro está deshabilitado y la pantalla explica que una venta a cuenta corriente se le carga a un cliente

#### Scenario: El saldo del cliente es visible antes de cobrar

- **GIVEN** un cliente con saldo deudor y la forma de pago de `kind = 'credit'` elegida
- **WHEN** el usuario tiene un carrito armado
- **THEN** ve el saldo actual del cliente y el saldo que quedará después de esta venta

#### Scenario: Elegir cuenta corriente no exige sesión de caja

- **GIVEN** una cuenta sin sesión de caja abierta
- **WHEN** el usuario elige en el POS la forma de pago de `kind = 'credit'` y cobra
- **THEN** la venta se confirma sin exigir sesión de caja y sin generar movimiento de caja

### Requirement: Lectura de la forma de pago en operaciones nacidas en el POS

El sistema SHALL persistir `payment_method_id` en todas las filas legacy de `sales` de una venta nacida en el POS cuando la orden lleva forma de pago imputada, de modo que las ventas nuevas no dependan de ninguna derivación. Para las operaciones históricas cuyas filas de `sales` no tienen `payment_method_id`, el sistema SHALL conservar la derivación **de lectura** desde el `payment_method_id` de la orden de venta asociada (`sales_orders`), resolviendo el catálogo por identidad y NO por `kind`. La imputación explícita SHALL ganar siempre sobre la derivación, y la derivación NO SHALL escribir en `sales`, `sales_orders` ni `payment_methods`.

La derivación por identidad SHALL reemplazar a la derivación por `kind`: `payment_methods.kind` no es único dentro de una cuenta, por lo que un JOIN por `kind` puede devolver más de una fila y duplicar la operación en los listados. El JOIN SHALL ser por `payment_methods.id = sales_orders.payment_method_id`.

#### Scenario: Venta nueva del POS trae su forma de pago persistida

- **WHEN** se cobra desde el POS eligiendo una forma de pago del catálogo
- **THEN** todas las filas de `sales` de esa operación quedan con ese `payment_method_id`, sin necesidad de derivación

#### Scenario: Venta histórica sin imputación se sigue mostrando por derivación

- **GIVEN** una venta previa cuyas filas de `sales` tienen `payment_method_id = NULL` pero cuya orden de venta tiene `payment_method_id` imputado
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación se muestra con la forma de pago de la orden, y ninguna fila de `sales` es modificada por la lectura

#### Scenario: La imputación explícita gana sobre la derivación

- **GIVEN** una operación con `payment_method_id` persistido en `sales`
- **WHEN** se lista
- **THEN** se muestra la forma de pago persistida, sin consultar la orden de venta

#### Scenario: Dos formas de pago del mismo kind no duplican la operación

- **GIVEN** una cuenta con dos formas de pago vivas de `kind = 'transfer'` y una venta del POS imputada a una de ellas
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación aparece exactamente una vez, con la forma de pago efectivamente imputada

#### Scenario: Operación sin forma de pago resoluble se muestra sin imputar

- **GIVEN** una venta cuyas filas de `sales` y cuya orden de venta tienen ambas `payment_method_id = NULL`
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación se muestra sin forma de pago ("Sin especificar"), sin error

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

El sistema SHALL exponer la forma de pago en: (a) el gestor del catálogo dentro de `/configuracion`, junto al de centros de costo, visible sólo para `owner`/`admin`, **incluyendo la asignación del destino bancario por defecto de cada forma de pago, con el estado sin destino rotulado como "no registra movimiento bancario"**; (b) un selector "Forma de pago" en el alta y edición de ventas y de compras, que ofrece sólo las formas activas, **acompañado de un selector de cuenta bancaria que aparece únicamente cuando el `kind` elegido es bancario y la organización tiene cuentas bancarias cargadas**; (c) un badge con la forma de pago y un filtro por forma de pago en los listados de ventas y de compras; (d) la pantalla `/reportes/formas-pago`, alcanzable desde una entrada propia del sidebar y sin gate de plan —mismo criterio que el reporte de centros de costo, porque gatearlo dejaría al plan free imputando datos que no puede leer; y (e) la grilla de formas de pago del POS (`/ventas/pos`), con sus estados propios: indicador de sesión de caja cuando el `kind` es `cash`, bloque de cliente y saldo cuando es `credit`, **y un indicador de cuenta bancaria destino cuando el `kind` es bancario, que muestra el destino resuelto y permite cambiarlo en una sola pulsación sin bloquear el cobro**. La superficie del POS NO SHALL exigir elegir cuenta bancaria para cobrar, y NO SHALL mostrar el indicador cuando la organización no tiene cuentas bancarias cargadas, de modo que el mostrador conserve su fricción actual para quien no lleva el banco en el sistema. Toda superficie nueva SHALL usar los tokens semánticos y los componentes base del design system, y SHALL verificarse en desktop y mobile y en tema claro y oscuro.

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

#### Scenario: El POS muestra el estado de caja sólo para efectivo

- **GIVEN** un usuario en el POS
- **WHEN** elige una forma de pago de `kind` distinto de `cash`
- **THEN** el indicador de sesión de caja no se muestra y el cobro no queda condicionado a una sesión abierta

#### Scenario: El POS muestra el destino bancario resuelto sin pedir una pulsación

- **GIVEN** una organización con cuentas bancarias y la forma de pago "Transferencia bancaria" con destino "Galicia CC"
- **WHEN** el usuario elige esa forma de pago en el POS
- **THEN** ve el destino "Galicia CC" indicado junto a la grilla, con la opción de cambiarlo, y puede cobrar sin ninguna pulsación adicional

#### Scenario: El POS no muestra nada bancario si la organización no tiene cuentas

- **GIVEN** una organización sin ninguna cuenta bancaria cargada
- **WHEN** el usuario elige una forma de pago de `kind = 'transfer'` en el POS
- **THEN** no se muestra indicador ni selector de cuenta bancaria y el cobro procede igual que antes de este change

#### Scenario: El gestor del catálogo permite configurar el destino

- **GIVEN** un `owner` en `/configuracion`
- **WHEN** abre el gestor de formas de pago
- **THEN** ve para cada forma su destino bancario (o el rótulo de que no registra movimiento bancario) y puede asignarlo o quitarlo desde ahí

### Requirement: Endpoints de formas de pago en el backend

El sistema SHALL exponer el catálogo y el reporte a través del backend FastAPI en las tres capas (router → service → repository), con validación Pydantic v2 en el endpoint, guardas de rol en el service y errores en formato RFC 7807 según `api-standards`. El frontend NO SHALL escribir el catálogo directamente contra Supabase.

#### Scenario: Listar formas de pago activas

- **WHEN** el frontend pide el catálogo sin incluir inactivas
- **THEN** el backend devuelve sólo las formas vivas y activas de la cuenta del usuario autenticado

#### Scenario: Crear sin rol suficiente

- **WHEN** un `member` hace POST al endpoint de creación
- **THEN** el backend responde 403 en formato RFC 7807, sin tocar la base

### Requirement: La forma de pago imputada determina la contrapartida contable de la compra

El sistema SHALL propagar el `kind` de la forma de pago imputada a una compra hasta el evento de dominio que alimenta la partida doble, de modo que la contrapartida del asiento refleje cómo se pagó realmente la compra. Una compra sin forma de pago imputada SHALL propagarse como `credit`, preservando el comportamiento histórico.

#### Scenario: Compra en efectivo no queda como deuda con el proveedor

- **WHEN** se registra una compra imputada a una forma de pago de `kind = 'cash'`
- **THEN** el evento emitido transporta `payment_method = 'cash'` y el asiento acredita la cuenta de caja, no la de proveedores

#### Scenario: Compra sin forma de pago conserva el comportamiento anterior

- **WHEN** se registra una compra sin forma de pago imputada
- **THEN** el evento emitido transporta `payment_method = 'credit'` y el asiento acredita la cuenta de proveedores

### Requirement: Destino bancario por defecto de la forma de pago

El sistema SHALL permitir asociar a cada forma de pago del catálogo una cuenta bancaria destino por defecto (`payment_methods.bank_account_id`, nullable, FK a `bank_accounts` con `ON DELETE SET NULL`), de modo que una organización configure **una sola vez** a qué cuenta entra el dinero de cada método y no vuelva a decidirlo en cada operación. El destino SHALL ser opcional: una forma de pago sin destino configurado NO SHALL registrar movimiento bancario, y ese es el estado inicial de todas las formas de pago sembradas por el provisioning. La asignación SHALL validarse contra la organización (la cuenta bancaria pertenece a la misma cuenta, está activa y no está borrada) y SHALL estar gateada por el mismo rol que el resto de la gestión del catálogo (`owner`/`admin`). La actualización del destino SHALL usar contrato tri-estado —no informado (conserva), informado con valor (asigna), informado en nulo (desasigna)— para que desasignar el destino sea expresable y no se confunda con no tocarlo. Configurar un destino sobre una forma de pago cuyo `kind` no es bancario SHALL rechazarse, porque ese destino nunca se usaría.

#### Scenario: Asignar el destino bancario a una forma de pago

- **GIVEN** un `owner` con una cuenta bancaria activa "Galicia CC"
- **WHEN** asigna esa cuenta como destino de la forma de pago "Transferencia bancaria"
- **THEN** la forma de pago queda con ese destino y las ventas siguientes por ese método registran su movimiento contra "Galicia CC"

#### Scenario: Desasignar el destino bancario

- **WHEN** el `owner` actualiza la forma de pago informando el destino en nulo
- **THEN** la forma de pago queda sin destino y las ventas siguientes por ese método no registran movimiento bancario

#### Scenario: Actualizar el nombre no toca el destino

- **WHEN** el `owner` renombra la forma de pago sin informar el campo de destino
- **THEN** el destino bancario configurado se conserva sin cambios

#### Scenario: Las formas de pago sembradas nacen sin destino

- **WHEN** se provisiona una cuenta nueva y se siembra su catálogo de formas de pago
- **THEN** todas las formas nacen sin destino bancario y ninguna operación registra movimiento bancario hasta que alguien lo configure

#### Scenario: Un member no puede configurar el destino

- **WHEN** un usuario con rol `member` intenta asignar el destino bancario de una forma de pago
- **THEN** la operación es rechazada por rol y el catálogo no cambia

#### Scenario: Destino bancario sobre un kind no bancario es rechazado

- **WHEN** se intenta asignar una cuenta bancaria como destino de una forma de pago de `kind = 'cash'`
- **THEN** la operación es rechazada y la forma de pago queda sin destino

#### Scenario: Borrar la cuenta bancaria degrada el default sin romper el catálogo

- **GIVEN** una forma de pago con destino "Galicia CC"
- **WHEN** esa cuenta bancaria se elimina
- **THEN** la forma de pago queda sin destino y sigue siendo usable, sin registrar movimiento bancario

