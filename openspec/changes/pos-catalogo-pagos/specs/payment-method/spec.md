## ADDED Requirements

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

### Requirement: El vocabulario de `sales_orders.payment_method` es el vocabulario del catálogo

El sistema SHALL mantener un único vocabulario de formas de pago: el conjunto admitido por el CHECK de `sales_orders.payment_method` SHALL ser idéntico al admitido por `payment_methods.kind` (`cash`, `transfer`, `card`, `check`, `wallet`, `credit`, `other`). Cuando una orden de venta tiene `payment_method_id` imputado, su `payment_method` SHALL ser igual al `kind` de esa forma de pago; el texto SHALL ser escrito por la RPC y nunca elegido por el cliente. La columna `payment_method` SHALL conservarse como columna derivada —no se dropea en este change— documentada con un `COMMENT` que declare que su fuente es `payment_method_id`.

#### Scenario: Los dos vocabularios coinciden

- **WHEN** se inspeccionan las definiciones de `sales_orders_payment_method_check` y `payment_methods_kind_check`
- **THEN** ambos enumeran exactamente el mismo conjunto de valores

#### Scenario: El texto legacy queda derivado del kind

- **WHEN** se confirma una venta imputada a una forma de pago de `kind = 'wallet'`
- **THEN** la orden queda con `payment_method_id` de esa forma de pago y `payment_method = 'wallet'`

#### Scenario: Una venta histórica sin imputación conserva su texto

- **GIVEN** una orden anterior a este change con `payment_method = 'other'` cuyo backfill no encontró forma de pago viva
- **WHEN** se la consulta
- **THEN** conserva `payment_method = 'other'` con `payment_method_id = NULL` y se muestra por derivación de lectura

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

### Requirement: La forma de pago dispara efectos según el camino, no según la etiqueta

El sistema SHALL determinar los efectos sobre caja y cuenta corriente por el **camino** que registra la operación, no por la etiqueta elegida. En el camino del mostrador (POS / `quickSale` / confirmación de orden de venta), la forma de pago SHALL ser tipada: `kind = 'cash'` exige sesión de caja abierta y genera `cash_movements`; `kind = 'credit'` exige cliente y postea el cargo en `customer_account_movements`. En el camino de los formularios de venta y de compra, `sales.payment_method_id` / `purchases.payment_method_id` SHALL ser **sólo etiqueta**: NO SHALL exigir sesión de caja, NO SHALL generar `cash_movements`, NO SHALL generar cargo en cuentas corrientes de cliente ni de proveedor, y NO SHALL generar `bank_movements` ni asiento contable. Los `kind` sin cableado (`transfer`, `card`, `check`, `wallet`) SHALL comportarse como etiqueta en todos los caminos. Las superficies que ofrecen el selector SHALL declarar explícitamente esta división, nombrando el POS como el camino que sí mueve caja, de forma que la etiqueta no se lea como una afordancia que el sistema no cumple.

#### Scenario: Venta en efectivo desde el form no mueve caja

- **GIVEN** una cuenta sin sesión de caja abierta
- **WHEN** se registra una venta con la forma de pago de `kind = 'cash'` desde el form de venta
- **THEN** la venta se registra normalmente, no se crea ningún `cash_movement` y no se exige sesión

#### Scenario: Venta en efectivo desde el POS sí mueve caja

- **GIVEN** una sesión de caja abierta en la sucursal
- **WHEN** se cobra desde el POS con la forma de pago de `kind = 'cash'`
- **THEN** se crea un `cash_movements` de tipo `sale` por el total, en el mismo commit que el descuento de stock

#### Scenario: Etiqueta de cuenta corriente en el form no genera cargo

- **WHEN** se registra una venta desde el form con la forma de pago de `kind = 'credit'`
- **THEN** la venta queda imputada a esa forma de pago, no se crea ningún movimiento en `customer_account_movements`, y el form informa dónde sí se registra el cargo

#### Scenario: Forma de pago de transferencia no genera movimiento bancario

- **WHEN** se cobra desde el POS con una forma de pago de `kind = 'transfer'`
- **THEN** la venta se confirma, no se crea ningún `bank_movements` ni asiento, y la operación queda imputada a esa forma de pago

#### Scenario: El texto de apoyo nombra el camino que mueve caja

- **WHEN** el usuario elige en el form de venta una forma de pago de `kind = 'cash'`
- **THEN** la pantalla explica que el movimiento de caja lo genera la venta desde el POS, con un enlace a esa pantalla

## REMOVED Requirements

### Requirement: La forma de pago es una etiqueta y no dispara asientos, caja ni cuenta corriente

**Reason**: La regla era absoluta ("la forma de pago NUNCA dispara efectos") y este change la vuelve falsa en el camino del mostrador, donde `kind = 'cash'` mueve caja y `kind = 'credit'` postea el cargo en la cuenta corriente. La reemplaza el requirement "La forma de pago dispara efectos según el camino, no según la etiqueta", que conserva íntegra la garantía para el camino de los formularios y agrega la del POS.

**Migration**: Ninguna migración de datos. La garantía que sostenía este requirement —una forma de pago imputada desde el form de venta o de compra no genera `cash_movements`, `customer_account_movements`, `bank_movements` ni asiento— sigue vigente palabra por palabra dentro del requirement que lo reemplaza, con sus escenarios preservados.

## MODIFIED Requirements

### Requirement: Lectura de la forma de pago en operaciones nacidas en el POS

El sistema SHALL persistir `payment_method_id` en todas las filas legacy de `sales` de una venta nacida en el POS cuando la orden lleva forma de pago imputada, de modo que las ventas nuevas no dependan de ninguna derivación. Para las operaciones históricas sin imputación, el sistema SHALL conservar la derivación **de lectura** desde el texto legacy de `sales_orders.payment_method` mapeado por `kind`, como fallback. La imputación explícita SHALL ganar siempre sobre la derivación, y la derivación NO SHALL escribir en `sales`, `sales_orders` ni `payment_methods`.

#### Scenario: Venta nueva del POS trae su forma de pago persistida

- **WHEN** se cobra desde el POS eligiendo una forma de pago del catálogo
- **THEN** todas las filas de `sales` de esa operación quedan con ese `payment_method_id`, sin necesidad de derivación

#### Scenario: Venta histórica sin imputación se sigue mostrando por derivación

- **GIVEN** una venta previa a este change cuya orden tiene `payment_method = 'cash'` y cuyas filas de `sales` tienen `payment_method_id = NULL`
- **WHEN** el usuario abre el listado de ventas
- **THEN** la operación se muestra con la forma de pago de `kind = 'cash'` de la cuenta, y ninguna fila de `sales` es modificada por la lectura

#### Scenario: La imputación explícita gana sobre la derivación

- **GIVEN** una operación con `payment_method_id` persistido
- **WHEN** se lista
- **THEN** se muestra la forma de pago persistida, sin consultar el texto legacy de la orden

### Requirement: Superficies de la forma de pago

El sistema SHALL exponer la forma de pago en: (a) el gestor del catálogo dentro de `/configuracion`, junto al de centros de costo, visible sólo para `owner`/`admin`; (b) un selector "Forma de pago" en el alta y edición de ventas y de compras, que ofrece sólo las formas activas; (c) un badge con la forma de pago y un filtro por forma de pago en los listados de ventas y de compras; (d) la pantalla `/reportes/formas-pago`, alcanzable desde una entrada propia del sidebar y sin gate de plan —mismo criterio que el reporte de centros de costo, porque gatearlo dejaría al plan free imputando datos que no puede leer; y **(e) la grilla de formas de pago del POS (`/ventas/pos`)**, con sus estados propios: indicador de sesión de caja cuando el `kind` es `cash` y bloque de cliente y saldo cuando es `credit`. Toda superficie nueva SHALL usar los tokens semánticos y los componentes base del design system, y SHALL verificarse en desktop y mobile y en tema claro y oscuro.

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
