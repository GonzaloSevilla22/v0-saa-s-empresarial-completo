## MODIFIED Requirements

### Requirement: PaymentMade reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_made(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_purchase_id uuid DEFAULT NULL, p_payment_method_id uuid DEFAULT NULL, p_bank_account_id uuid DEFAULT NULL, p_cash_session_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) **resuelve el `kind` de la forma de pago** consultando el catálogo por `p_payment_method_id` **bajo el `account_id` del tenant**, rechazando con `P0404` la forma de pago inexistente o de otra cuenta, con un mensaje que no revela cuál de los dos casos ocurrió; (c) resuelve o crea la `SupplierAccount`; (d) aplica idempotencia DEC-06 con `operation_kind = 'payment_made'`; (e) invoca el helper con `amount` negativo (`payment_made` reduce lo que se debe); (f) inserta una fila en `payments_made` con `payment_method_id`; (g) **rutea el egreso de fondos por el `kind` derivado**: cuando el `kind` es bancario (`transfer` / `card` / `check` / `wallet`) SHALL delegar en el **helper compartido de movimiento bancario de operaciones** —el mismo que usan la venta, la compra y el gasto— con dirección de egreso, `source_doc_type = 'payment_made'` y `source_doc_ref` = id del pago, obteniendo de él el mapa `kind → movement_type` (`card_settlement` para `card`, `transfer_out` para el resto) y el guard de período conciliado (`P0424`); cuando es `cash` **y se informa `p_cash_session_id`** SHALL invocar el helper intra-transaccional de caja con `amount` negativo, `movement_type = 'payment_made'` y referencia al pago, sin tocar el ledger bancario; cuando es `cash` **sin** `p_cash_session_id`, o cuando el `kind` es `other`, o cuando no se informa forma de pago, SHALL registrar el pago sin efecto sobre ningún libro de dinero; (h) emite el evento `PaymentMade` al outbox con el `kind` derivado y `payment_method_id` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`.

El `kind` NO SHALL aceptarse como dato del cliente: la función NO SHALL contener ninguna enumeración literal de formas de pago. Una forma de pago de `kind = 'credit'` SHALL rechazarse con `P0400`, porque cancelar una cuenta corriente con cuenta corriente es circular.

Un `kind` bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`); esa exigencia SHALL conservarse aunque el helper compartido admita resolver la cuenta desde el destino configurado en la forma de pago, porque un destino sin configurar haría que el helper no escribiera el movimiento **sin levantar error**. Informar `p_cash_session_id` con un `kind` distinto de `cash` SHALL rechazarse con `P0422 cash_optin_requires_cash_kind`, y con una sesión que no esté `open` SHALL rechazarse con `P0422 cash_optin_requires_open_session`; la pertenencia de la sesión a la cuenta la aporta el punto de paso obligado del registro de movimientos de caja. El movimiento de caja SHALL quedar **dentro** del alcance de la clave de idempotencia: un replay SHALL devolver el resultado original sin registrar un segundo movimiento.

`payments_made` SHALL persistir la forma de pago como `payment_method_id` con FK al catálogo, y NO SHALL conservar además una columna de texto con el mismo dato. El parámetro `p_payment_method_id` es **opcional** (`NULL` = sin imputar), y los pagos anteriores a este cambio SHALL permanecer sin imputar, sin backfill. La firma SHALL quedar como **única firma viva** de la función: la firma anterior —con la forma de pago como texto— SHALL eliminarse con `DROP FUNCTION` en la misma migración en lugar de convivir como sobrecarga, y los permisos SHALL re-otorgarse explícitamente porque el `DROP` los resetea. Un pago que excede el saldo sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar pago disminuye el saldo
- **WHEN** se registra un `PaymentMade` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `supplier_account_movement` de tipo `payment_made` con `amount = −400` y `balance_after = 600`, y una fila en `payments_made`

#### Scenario: pago idempotente no duplica
- **WHEN** se llama `rpc_register_payment_made` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo pago, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si el `kind` es bancario), se inserta un solo `cash_movement` (si se informó sesión de caja) y la segunda llamada devuelve el resultado original

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentMade` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: pago por transferencia registra egreso bancario en la misma transacción
- **WHEN** se registra un `PaymentMade` de 400 imputado a una forma de pago de `kind = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `SupplierAccount` queda en `balance = 600`, existe una fila en `payments_made`, y existe un `bank_movement` de `amount = −400`, `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: pago por billetera virtual registra egreso bancario
- **WHEN** se registra un `PaymentMade` imputado a una forma de pago de `kind = 'wallet'` con una cuenta bancaria activa
- **THEN** se crea un `bank_movement` de egreso con `movement_type = 'transfer_out'` sobre esa cuenta, en el mismo commit

#### Scenario: pago imputado a `other` no toca ningún libro de dinero
- **WHEN** se registra un `PaymentMade` de 400 imputado a una forma de pago de `kind = 'other'`
- **THEN** el saldo del proveedor se reduce a 600 y el pago queda imputado a esa forma de pago
- **AND** no se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: pago imputado a cuenta corriente es rechazado
- **WHEN** se registra un `PaymentMade` imputado a una forma de pago de `kind = 'credit'`
- **THEN** la operación falla con `P0400` y no se inserta ni el pago, ni el movimiento de cuenta corriente, ni ningún movimiento de dinero

#### Scenario: forma de pago de otro tenant es rechazada
- **WHEN** se registra un `PaymentMade` informando el identificador de una forma de pago de otra cuenta
- **THEN** la operación falla con `P0404` y no se inserta ninguna fila
- **AND** el mensaje no revela si el identificador existe en otra cuenta

#### Scenario: pago en efectivo con sesión de caja sale del cajón
- **WHEN** se registra un `PaymentMade` de 400 imputado a `kind = 'cash'` informando una sesión de caja abierta, sobre una cuenta con `balance = 1000`
- **THEN** el saldo del proveedor se reduce a 600, existe una fila en `payments_made`, y existe un `cash_movement` de tipo `payment_made` con `amount = −400` y referencia al pago, todo atómico en un solo commit
- **AND** no se inserta ninguna fila en `bank_movements`

#### Scenario: pago en efectivo sin sesión de caja no toca ningún libro de dinero
- **WHEN** se registra un `PaymentMade` de 400 imputado a `kind = 'cash'` sin informar sesión de caja
- **THEN** el saldo del proveedor se reduce a 600 y NO se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: sesión de caja con kind no efectivo es rechazada
- **WHEN** se registra un `PaymentMade` imputado a `kind = 'transfer'` informando una sesión de caja
- **THEN** la operación falla con `P0422 cash_optin_requires_cash_kind` y no se inserta ninguna fila

#### Scenario: sesión de caja cerrada es rechazada
- **WHEN** se registra un `PaymentMade` en efectivo informando una sesión de caja que no está `open`
- **THEN** la operación falla con `P0422 cash_optin_requires_open_session` y no se inserta ninguna fila

#### Scenario: kind bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentMade` imputado a un `kind` bancario y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400`/`P0412`) y no se inserta ni el pago ni el movimiento bancario
- **AND** la operación NO recae en el destino configurado en la forma de pago

#### Scenario: pago sin forma de pago imputada
- **WHEN** se invoca `rpc_register_payment_made` sin `p_payment_method_id` ni `p_cash_session_id`
- **THEN** el pago se registra con la imputación vacía y sin impacto en ningún libro de dinero

#### Scenario: no queda una sobrecarga con la firma anterior
- **WHEN** se inspeccionan las funciones de registro de pago tras la migración
- **THEN** existe exactamente una definición viva, con la forma de pago como identificador del catálogo, y sus permisos re-otorgados explícitamente
- **AND** no existe ninguna definición que reciba la forma de pago como texto

### Requirement: La superficie de pago a proveedor ofrece el impacto en caja pre-marcado y explica cuándo no aplica

La interfaz de registro de un pago a proveedor SHALL ofrecer las formas de pago del **catálogo de la cuenta** a través del componente selector compartido, en el **mismo contexto de cobranza** que el modal de cobro —el conjunto de opciones es idéntico— y NO SHALL declarar una lista propia de opciones.

Cuando la forma de pago elegida tiene `kind = 'cash'`, SHALL ofrecer la afirmación del impacto en caja **pre-marcada** si existe una sesión abierta, y SHALL mostrar el motivo concreto cuando no la hay, sin ocultar el bloque en silencio. Es el espejo exacto de la superficie de cobro, y SHALL reutilizar la misma resolución de condiciones compartida en lugar de reimplementarla, alimentándola con el `kind` derivado del catálogo y no con el valor del control de selección.

#### Scenario: Efectivo con caja abierta

- **GIVEN** una sesión de caja abierta en la cuenta
- **WHEN** el usuario elige una forma de pago de `kind = 'cash'` en el modal de pago a proveedor
- **THEN** la afirmación de impacto en caja aparece marcada, nombrando la sesión

#### Scenario: Efectivo sin caja abierta

- **GIVEN** ninguna sesión de caja abierta
- **WHEN** el usuario elige una forma de pago de `kind = 'cash'` en el modal de pago a proveedor
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta
- **AND** el pago puede registrarse de todos modos, sin impacto en el arqueo

#### Scenario: Los dos modales ofrecen el mismo conjunto de opciones

- **WHEN** se comparan las opciones del selector en el modal de cobro y en el de pago a proveedor
- **THEN** ambos ofrecen las mismas formas de pago activas del catálogo, sin las de `kind = 'credit'`
- **AND** ambos las resuelven por el mismo componente y el mismo contexto

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** un pago en efectivo con sesión abierta
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** el pago se registra sin movimiento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el modal de pago se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
- **AND** el desplegable del selector se despliega dentro del modal con todas sus opciones alcanzables

## ADDED Requirements

### Requirement: El historial de cuenta corriente del proveedor nombra la forma de pago configurada

El sistema SHALL exponer, para cada movimiento de tipo `payment_made` del historial de cuenta corriente del proveedor, el **nombre** de la forma de pago con la que se registró el pago, resuelto desde el catálogo a través de la imputación del documento. Es el espejo exacto del historial del cliente.

Un movimiento cuyo pago no tenga forma de pago imputada SHALL exponer el dato vacío, y la superficie SHALL omitir la mención en lugar de mostrar un valor inventado.

#### Scenario: Pago imputado muestra el nombre configurado

- **GIVEN** un pago imputado a una forma de pago que el usuario renombró
- **WHEN** se consulta el historial de cuenta corriente del proveedor
- **THEN** el movimiento del pago expone ese nombre

#### Scenario: Pago histórico sin imputar

- **GIVEN** un pago anterior a este cambio, sin forma de pago imputada
- **WHEN** se consulta el historial
- **THEN** el movimiento expone el dato vacío y la superficie no muestra ninguna forma de pago
