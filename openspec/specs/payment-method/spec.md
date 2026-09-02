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

El sistema SHALL restringir `payment_methods.kind` por CHECK al conjunto `{cash, transfer, card, check, wallet, credit, other}`, y ese CHECK SHALL ser el **único** lugar donde vive el vocabulario de formas de pago del sistema. El `name` SHALL ser la etiqueta que ve y edita el usuario; el `kind` SHALL ser lo único que consuman los subsistemas para razonar sobre la forma de pago. `sales_orders` NO SHALL tener una columna de texto con su propia copia del vocabulario: la forma de pago de una orden SHALL leerse siempre por `payment_method_id → payment_methods.kind`.

Ninguna función de registro de documentos SHALL conservar una taxonomía de formas de pago propia. En particular, las RPCs de cobro de cuenta corriente y de pago a proveedor —que hasta este cambio validaban un parámetro de texto contra el subconjunto propio `{cash, transfer, card, check}` escrito en su cuerpo— SHALL recibir un identificador del catálogo y derivar el `kind` de él. Con esa retirada, **ningún** subconjunto propio del vocabulario sobrevive en el sistema.

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

#### Scenario: Las RPCs de cobro y pago no conservan su propia lista

- **WHEN** se inspecciona el cuerpo vivo de las funciones de registro de cobro de cuenta corriente y de pago a proveedor
- **THEN** ninguna contiene una enumeración literal de formas de pago
- **AND** ambas resuelven el `kind` consultando el catálogo por el identificador recibido

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

El sistema SHALL determinar los efectos sobre caja y cuenta corriente por el **camino** que registra la operación combinado con el `kind` de la forma de pago, y SHALL derivar ese `kind` en el servidor a partir de `payment_method_id`, nunca aceptándolo como dato del cliente. En el camino del mostrador (POS / `quickSale` / confirmación de orden de venta) los efectos SHALL ser automáticos: `kind = 'cash'` exige sesión de caja abierta y genera `cash_movements`; `kind = 'credit'` exige cliente y postea el cargo en `customer_account_movements`. En el camino de los formularios de venta y de compra, `kind = 'credit'` SHALL exigir la parte identificada (cliente en venta, proveedor en compra) y postear el cargo en la cuenta corriente correspondiente, mientras que `kind = 'cash'` SHALL generar `cash_movements` **sólo** ante un opt-in explícito del usuario que cumpla las tres condiciones de servidor definidas en la capability `cash-session` — **en los dos formularios por igual**: la venta genera un movimiento de tipo `sale` y la compra uno de tipo `purchase_payment` con signo de egreso. Los `kind` bancarios (`transfer`, `card`, `check`, `wallet`) SHALL generar un `bank_movement` en el ledger operativo —en todos los caminos de alta de venta y de compra— **únicamente** cuando se resuelva una cuenta bancaria destino según las reglas de la capability `bank-movement`; sin destino resuelto SHALL comportarse como etiqueta, que es el estado inicial de toda forma de pago sembrada. El `kind = 'other'` SHALL comportarse siempre como etiqueta a efectos de caja, cuenta corriente y banco. Nada de esto SHALL alterar la contrapartida contable que la capability `journal-entry` asigna a cada `kind`, que se sigue posteando de forma asíncrona por el outbox y es independiente del ledger operativo. Las superficies que ofrecen el selector SHALL declarar explícitamente qué efecto tiene cada elección, de forma que la etiqueta no se lea como una afordancia que el sistema no cumple ni oculte un efecto que sí produce.

La simetría entre venta y compra SHALL ser total en la rama de efectivo: hasta este cambio la compra imputada a `kind = 'cash'` era la única imputación del catálogo que no producía **ningún** efecto en ningún libro —ni caja, ni banco, ni cuenta corriente—, de modo que la etiqueta describía un hecho que el sistema no registraba en ninguna parte.

#### Scenario: Venta en efectivo desde el form sin opt-in no mueve caja

- **GIVEN** una cuenta sin sesión de caja abierta
- **WHEN** se registra una venta con la forma de pago de `kind = 'cash'` desde el form de venta
- **THEN** la venta se registra normalmente, no se crea ningún `cash_movement` y no se ofrece el opt-in

#### Scenario: Venta en efectivo desde el form con opt-in mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal de la venta
- **WHEN** se registra hoy una venta con la forma de pago de `kind = 'cash'` desde el form marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `sale` por el total, en el mismo commit que el descuento de stock

#### Scenario: Compra en efectivo desde el form con opt-in mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal de la compra
- **WHEN** se registra hoy una compra con la forma de pago de `kind = 'cash'` desde el form marcando el opt-in de caja
- **THEN** se crea un `cash_movements` de tipo `purchase_payment` con signo de egreso por el total, en el mismo commit que el ingreso de stock

#### Scenario: Compra en efectivo desde el form sin opt-in no mueve caja

- **WHEN** se registra una compra con la forma de pago de `kind = 'cash'` sin marcar el opt-in
- **THEN** la compra se registra normalmente y no se crea ningún `cash_movement` ni `bank_movement`

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

- **WHEN** el usuario elige en el form de venta o en el de compra una forma de pago de `kind = 'cash'`, de `kind = 'credit'` o de un `kind` bancario con destino configurado
- **THEN** la pantalla explica qué va a ocurrir con la caja, con la cuenta corriente de la parte o con la cuenta bancaria antes de confirmar

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

El sistema SHALL exponer `rpc_payment_method_report(p_account_id, p_start, p_end)` que agregue, por forma de pago y para el rango pedido, el total vendido, el total comprado y el **total gastado**, con una fila propia para las operaciones sin imputar ("Sin especificar"). El RPC SHALL ser `SECURITY DEFINER` con `search_path` fijo y SHALL verificar la membresía del caller sobre `p_account_id` (P0401), espejando `rpc_cost_center_report`. SHALL cumplir los invariantes RN-D: importe de línea con `COALESCE(total, amount)`, conteo de operaciones con `COUNT(DISTINCT COALESCE(operation_id, id))`, bordes `date >= p_start AND date < (p_end + 1)`, y todo importe de salida `NUMERIC`. Los gastos SHALL sumarse por `amount` y SHALL contarse una unidad por fila de gasto, con el mismo criterio con que `rpc_cost_center_report` ya los agrega. **Excepción documentada a RN-D1**: el reporte NO SHALL restar notas de crédito, porque una NC no tiene forma de pago atribuible; la excepción SHALL estar visible en la propia pantalla del reporte, igual que la ya documentada para el margen por canal.

#### Scenario: Agregación por forma de pago

- **GIVEN** en el rango: dos ventas en "Efectivo" por $10.000 y $5.000, una en "Transferencia bancaria" por $20.000 y una compra en "Efectivo" por $3.000
- **WHEN** se ejecuta el reporte sobre ese rango
- **THEN** "Efectivo" muestra $15.000 vendidos y $3.000 comprados, y "Transferencia bancaria" $20.000 vendidos

#### Scenario: Los gastos participan de la agregación

- **GIVEN** en el rango: un gasto de $4.000 imputado a "Efectivo" y otro de $6.000 imputado a "Transferencia bancaria"
- **WHEN** se ejecuta el reporte sobre ese rango
- **THEN** "Efectivo" muestra $4.000 gastados y "Transferencia bancaria" $6.000 gastados
- **AND** los importes de gasto no se mezclan con los de compra

#### Scenario: Operaciones sin imputar

- **GIVEN** ventas históricas con `payment_method_id = NULL` dentro del rango
- **WHEN** se ejecuta el reporte
- **THEN** aparecen agrupadas en una fila "Sin especificar" y no se reparten entre las demás formas de pago

#### Scenario: Los gastos históricos sin imputar aparecen agrupados

- **GIVEN** gastos anteriores a este cambio, sin forma de pago, dentro del rango
- **WHEN** se ejecuta el reporte
- **THEN** aparecen agrupados en la fila "Sin especificar"
- **AND** no se reparten entre las demás formas de pago

#### Scenario: Caller de otra cuenta

- **WHEN** un usuario que no es miembro de `p_account_id` ejecuta el reporte
- **THEN** la llamada es rechazada con P0401

#### Scenario: La pantalla del reporte muestra la columna de gastos

- **WHEN** un usuario abre el reporte de formas de pago
- **THEN** la tabla incluye una columna de gastos junto a las de ventas y compras
- **AND** los totales de la pantalla coinciden con los del read-model

### Requirement: Superficies de la forma de pago

Toda superficie que ofrezca elegir o filtrar una forma de pago SHALL consumir el catálogo de la cuenta a través del **mismo componente selector**, y NO SHALL declarar una lista propia de opciones. El selector SHALL aceptar un **contexto** que determine qué formas de pago ofrece y qué texto de apoyo muestra, de modo que la variación por documento sea una extensión aditiva del componente único y nunca un selector paralelo.

Los contextos SHALL ser: venta, compra, gasto y **cobranza** —este último compartido por el cobro de una cuenta corriente de cliente y el pago a un proveedor, porque ambos ofrecen exactamente el mismo conjunto de formas de pago y difieren únicamente en la dirección del dinero—. En los contextos de gasto y de cobranza el selector NO SHALL ofrecer las formas de pago de `kind = 'credit'`.

El texto de apoyo SHALL describir el efecto real de la elección en el documento que se está registrando, incluyendo si el impacto en caja se ofrece marcado o desmarcado por defecto; una superficie NO SHALL afirmar que una forma de pago es una mera etiqueta cuando en ese camino produce un movimiento en algún libro.

#### Scenario: Alta de venta con el selector

- **WHEN** el usuario abre el formulario de alta de venta
- **THEN** ve el selector de forma de pago con las opciones activas de su cuenta, ordenadas por `sort_order`

#### Scenario: Alta de gasto con el selector

- **WHEN** el usuario abre el formulario de alta de gasto
- **THEN** ve el selector con las formas de pago activas de su cuenta, sin las de `kind = 'credit'`

#### Scenario: Cobro de cuenta corriente con el selector

- **WHEN** el usuario abre el modal de registro de un cobro de cuenta corriente
- **THEN** ve el selector con las formas de pago activas de su cuenta, con los nombres que él configuró, sin las de `kind = 'credit'`
- **AND** no ve ninguna lista fija de opciones ajena a su catálogo

#### Scenario: Pago a proveedor con el selector

- **WHEN** el usuario abre el modal de registro de un pago a proveedor
- **THEN** ve el mismo conjunto de opciones que en el modal de cobro, resuelto por el mismo componente y el mismo contexto

#### Scenario: Renombrar una forma de pago se refleja en la cobranza

- **GIVEN** un usuario que renombró "Transferencia bancaria" a "Banco Nación" en el gestor del catálogo
- **WHEN** abre el modal de cobro
- **THEN** la opción aparece como "Banco Nación"

#### Scenario: El texto de apoyo del efectivo en cobranza declara el valor inicial marcado

- **WHEN** el usuario elige en el modal de cobro o de pago una forma de pago de `kind = 'cash'`
- **THEN** el texto de apoyo dice que el movimiento se registra en la caja abierta salvo que se desmarque la afirmación
- **AND** no reutiliza la redacción del formulario de venta, cuya afirmación nace desmarcada

#### Scenario: El desplegable es operable dentro del modal

- **WHEN** el selector se despliega dentro del modal de cobro o de pago
- **THEN** la lista de opciones se desplaza dentro del modal y todas las opciones son alcanzables
- **AND** se comporta igual en escritorio y en móvil

#### Scenario: Presentación responsive y por tema en cobranza

- **WHEN** el modal de cobro o de pago se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** el selector usa los tokens semánticos del design system y es legible y operable en las cuatro combinaciones

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

### Requirement: Imputación opcional de la forma de pago en gastos

El sistema SHALL permitir imputar opcionalmente una forma de pago del catálogo a un gasto, mediante una columna nullable `payment_method_id` en `public.expenses`, con el mismo contrato que ya rige para ventas y compras: la forma de pago SHALL pertenecer a la cuenta del gasto y estar activa, el `kind` SHALL derivarse en el servidor desde el catálogo, y un gasto sin forma de pago SHALL ser válido.

La desactivación de una forma de pago SHALL preservar la imputación histórica de los gastos que la usan, igual que preserva la de ventas y compras: el gasto conserva su referencia y su nombre histórico sigue siendo legible en el listado y en el reporte.

#### Scenario: Alta de gasto con forma de pago

- **WHEN** se crea un gasto informando una forma de pago activa de la cuenta
- **THEN** el gasto queda persistido con esa forma de pago

#### Scenario: Gasto sin forma de pago

- **WHEN** se crea un gasto sin informar forma de pago
- **THEN** el gasto queda persistido sin imputación y sin efecto en libros

#### Scenario: Forma de pago de otra cuenta en un gasto

- **WHEN** se intenta crear un gasto con una forma de pago de otra cuenta
- **THEN** la operación es rechazada

#### Scenario: Desactivar una forma de pago usada por gastos

- **GIVEN** una forma de pago con gastos ya imputados
- **WHEN** se la desactiva
- **THEN** deja de ofrecerse para gastos nuevos
- **AND** los gastos históricos conservan su imputación y su nombre histórico sigue visible

### Requirement: La forma de pago dispara los efectos del gasto según su kind

El sistema SHALL despachar los efectos en libros de un gasto a partir del `kind` derivado de la forma de pago imputada, con el mismo criterio que ya rige para ventas y compras: `cash` habilita el impacto en la sesión de caja bajo opt-in verificado en servidor; `transfer`, `card`, `check` y `wallet` producen un movimiento bancario; `other` es una etiqueta sin efecto en libros; y `credit` SHALL rechazarse porque un gasto no tiene contraparte con cuenta corriente.

El texto de apoyo del selector SHALL nombrar el efecto de cada elección **en el contexto de gasto**, y SHALL NOT reutilizar el texto de venta, cuyos efectos son distintos.

#### Scenario: El kind del gasto se deriva en el servidor

- **WHEN** se registra un gasto informando una forma de pago
- **THEN** el efecto en libros se determina por el `kind` que el servidor lee del catálogo
- **AND** un `kind` enviado por el cliente no altera el efecto

#### Scenario: Gasto con forma de pago de tipo otro

- **WHEN** se registra un gasto con una forma de pago de `kind` `other`
- **THEN** el gasto queda persistido con su imputación
- **AND** no se registra ningún movimiento de caja ni bancario

#### Scenario: Gasto con forma de pago de cuenta corriente

- **WHEN** se intenta registrar un gasto con una forma de pago de `kind` `credit`
- **THEN** la operación es rechazada
- **AND** el texto de apoyo indica que un egreso a pagar después se registra como compra a proveedor

#### Scenario: El texto de apoyo distingue el contexto

- **WHEN** un usuario elige una forma de pago en el formulario de gasto
- **THEN** el texto de apoyo describe el efecto sobre caja o banco propio del gasto
- **AND** no describe efectos de venta como el cargo a la cuenta corriente de un cliente

### Requirement: La etiqueta de forma de pago tiene una sola definición en la interfaz

El sistema SHALL exponer la forma de pago de una operación en los listados mediante un componente único y compartido, alimentado por una definición canónica de las etiquetas en castellano de cada `kind` y del literal de "sin imputar", en lugar de repetir la marcación en cada listado.

Las etiquetas SHALL usar los tonos semánticos del design system y SHALL NOT usar colores literales, para no reintroducir la deuda de contraste que el gate vigente vigila.

#### Scenario: Los listados comparten la etiqueta

- **WHEN** se muestran las formas de pago en los listados de ventas, compras y gastos
- **THEN** los tres usan el mismo componente y la misma definición de etiquetas
- **AND** una operación sin imputar se muestra con el mismo literal en los tres

#### Scenario: La etiqueta usa tonos semánticos

- **WHEN** se inspecciona la etiqueta de forma de pago en cualquiera de los listados
- **THEN** sus colores provienen de los tokens semánticos del design system
- **AND** es legible en tema claro y en tema oscuro

### Requirement: Imputación de la forma de pago en cobros y pagos de cuenta corriente

El sistema SHALL imputar la forma de pago de un cobro de cuenta corriente y de un pago a proveedor mediante `payment_method_id`, con FK al catálogo de la cuenta, y SHALL derivar el `kind` en el servidor a partir de ese identificador. El `kind` NO SHALL aceptarse como dato del cliente por ningún camino.

La resolución del `kind` SHALL filtrar explícitamente por la cuenta del usuario: una forma de pago que no pertenezca al tenant SHALL rechazarse con el error de recurso no encontrado, con un mensaje que no revele si el identificador existe en otra cuenta.

Los `kind` admitidos SHALL ser seis de los siete del vocabulario: `cash` (impacto en caja bajo opt-in), `transfer`, `card`, `check` y `wallet` (movimiento bancario), y `other` (etiqueta sin efecto en ningún libro). El `kind = 'credit'` SHALL rechazarse con error de solicitud inválida, porque cancelar una cuenta corriente con cuenta corriente es circular: el cobro reduce la deuda de la parte y `credit` significa aumentarla. Ese rechazo SHALL sostenerse en el servidor **además** de no ofrecerse en la interfaz, de modo que la API no sea un bypass de la superficie.

La imputación SHALL ser opcional: un cobro sin forma de pago imputada SHALL registrarse normalmente, sin efecto sobre ningún libro de dinero, y los cobros anteriores a este cambio SHALL permanecer sin imputar, sin backfill.

#### Scenario: Cobro imputado a una forma de pago del catálogo

- **WHEN** se registra un cobro informando el identificador de una forma de pago activa de la cuenta
- **THEN** el cobro queda imputado a esa forma de pago y sus efectos se resuelven por el `kind` derivado del catálogo

#### Scenario: El kind no se acepta del cliente

- **WHEN** una solicitud de cobro informa un identificador de forma de pago junto con un texto que declara otro `kind`
- **THEN** el servidor ignora el texto y resuelve el `kind` del catálogo, o rechaza la solicitud
- **AND** los efectos aplicados son los del `kind` real de la forma de pago identificada

#### Scenario: Forma de pago de otro tenant es rechazada

- **GIVEN** el identificador de una forma de pago perteneciente a otra cuenta
- **WHEN** se registra un cobro informándolo
- **THEN** la operación falla con el error de recurso no encontrado
- **AND** no se inserta el cobro, ni el movimiento de cuenta corriente, ni ningún movimiento de dinero

#### Scenario: Cobro por billetera virtual

- **GIVEN** una forma de pago activa de `kind = 'wallet'` y una cuenta bancaria activa
- **WHEN** se registra un cobro imputado a ella
- **THEN** el cobro se registra y se crea un movimiento bancario de ingreso contra la cuenta indicada, en el mismo commit

#### Scenario: Cobro imputado a `other` no toca ningún libro

- **WHEN** se registra un cobro imputado a una forma de pago de `kind = 'other'`
- **THEN** el saldo de la parte se reduce, el cobro queda imputado a esa forma de pago
- **AND** no se crea ningún movimiento de caja ni bancario

#### Scenario: Cobro imputado a cuenta corriente es rechazado

- **WHEN** se registra un cobro imputado a una forma de pago de `kind = 'credit'`
- **THEN** la operación falla con error de solicitud inválida
- **AND** no se inserta el cobro ni ningún movimiento

#### Scenario: Cobro sin forma de pago imputada

- **WHEN** se registra un cobro sin informar forma de pago
- **THEN** el cobro se registra con la imputación vacía y sin efecto sobre ningún libro de dinero

#### Scenario: Los cobros entran al reporte de formas de pago

- **GIVEN** cobros imputados a distintas formas de pago del catálogo
- **WHEN** se consulta el reporte de distribución por forma de pago
- **THEN** los cobros se agrupan por su forma de pago imputada, igual que las ventas, las compras y los gastos

