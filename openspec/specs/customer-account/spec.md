# customer-account

> Synced from change `v21-customer-supplier-accounts` (C-30) — 2026-06-20

## Purpose

Cuentas corrientes de clientes: agregado `CustomerAccount` con saldo materializado + ledger append-only `customer_account_movements`. Permite registrar ventas a crédito (integración con C-29 `SalesOrder.confirm()`), cobros idempotentes, notas de crédito y ajustes manuales, todo mediante RPCs `SECURITY DEFINER` que preservan la invariante del saldo mediante `SELECT ... FOR UPDATE`. Cierra la Fase 7 del roadmap V2.
## Requirements
### Requirement: Agregado CustomerAccount con saldo materializado
El sistema SHALL proveer un agregado `CustomerAccount` (tabla `customer_accounts`) con `id`, `account_id` (tenancy, FK→`accounts`), `client_id` (FK→`clients`), `balance numeric(15,2) NOT NULL DEFAULT 0` (saldo materializado), `created_by`, `created_at`. SHALL existir a lo sumo **una** `CustomerAccount` por `(account_id, client_id)` (UNIQUE). Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER` (sin INSERT/UPDATE directo del rol `authenticated`); la RLS de lectura SHALL ser `account_id IN (SELECT public.current_account_ids())`.

El par `(account_id, client_id)` SHALL ser **coherente**: el `client_id` SHALL pertenecer al `account_id` de la propia fila. La clave foránea a `clients` no expresa esa restricción por sí sola —referencia el cliente sin exigir que sea del mismo tenant—, así que la coherencia SHALL garantizarse en la resolución/creación de la cuenta corriente, que es el único camino de escritura del agregado. Una `CustomerAccount` cuyo cliente pertenece a otro tenant SHALL considerarse un defecto de datos, no una configuración válida.

#### Scenario: crear cuenta corriente de un cliente
- **WHEN** se crea una `CustomerAccount` para un cliente de la cuenta
- **THEN** existe una fila en `customer_accounts` con `balance = 0` y `(account_id, client_id)` único

#### Scenario: una sola cuenta por cliente
- **WHEN** se intenta crear una segunda `CustomerAccount` para el mismo `(account_id, client_id)`
- **THEN** la operación es idempotente (no crea una segunda fila) y devuelve la cuenta existente

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `customer_accounts`
- **THEN** solo ve las cuentas cuyo `account_id` pertenece a su cuenta

#### Scenario: no existe cuenta corriente con cliente de otro tenant
- **WHEN** se recorre `customer_accounts` uniendo cada fila con su cliente
- **THEN** no existe ninguna fila cuyo `clients.account_id` difiera del `customer_accounts.account_id`

### Requirement: Ledger append-only de movimientos con balance_after
El sistema SHALL proveer un ledger `customer_account_movements` (`id`, `customer_account_id` FK→`customer_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `sale|payment_received|payment_received_reversal|credit_note|adjustment`, `reference_id uuid` nullable, **`due_date date` nullable**, `created_by`, `created_at`). El ledger SHALL ser **append-only**: la RLS SHALL tener únicamente política SELECT (sin UPDATE ni DELETE). Cada movimiento SHALL persistir su `balance_after` (saldo de la cuenta tras aplicar el movimiento). El `balance_after` SHALL computarse a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

El tipo `payment_received_reversal` SHALL designar la anulación de un cobro y SHALL postearse con importe **positivo** (repone la deuda). SHALL ser un tipo propio y SHALL NOT reutilizarse `credit_note` para expresarlo: `credit_note` designa la reversión de un **cargo** y se postea negativo, de modo que un `credit_note` positivo invertiría el significado del tipo para todo lector que dependa de su signo. Tampoco SHALL reutilizarse `adjustment`, reservado a la corrección manual.

`due_date` SHALL designar el **vencimiento del cargo** y SHALL poblarse únicamente en los movimientos que constituyen un cargo; en los demás SHALL quedar nulo. SHALL escribirse en el mismo `INSERT` que crea el movimiento y NO SHALL actualizarse después: es un dato congelado, no una función del plazo vigente. Su ausencia SHALL significar **"cargo sin vencimiento"**, y los movimientos anteriores a la incorporación de la columna SHALL conservarla nula, sin backfill.

La ampliación del CHECK SHALL ser aditiva e idempotente: ninguna fila existente SHALL ser invalidada ni reescrita. La incorporación de `due_date` SHALL ser igualmente aditiva y nullable: NO SHALL requerir valor para las filas existentes ni imponer restricción alguna sobre ellas.

#### Scenario: movimiento persiste balance_after
- **WHEN** se postea un movimiento de `amount = 1000` sobre una cuenta con `balance = 0`
- **THEN** la fila del ledger tiene `balance_after = 1000` y la cabecera `customer_accounts.balance` queda en `1000`

#### Scenario: ledger es append-only
- **WHEN** un usuario intenta UPDATE o DELETE sobre `customer_account_movements`
- **THEN** la operación es denegada por RLS (no hay política de UPDATE/DELETE)

#### Scenario: movement_type fuera del dominio es rechazado
- **WHEN** se intenta insertar un movimiento con `movement_type = 'foo'`
- **THEN** el CHECK rechaza la fila (`check_violation`)

#### Scenario: balance_after acumula correctamente en movimientos sucesivos
- **WHEN** sobre una cuenta en `balance = 0` se postea `+1000` (sale) y luego `−400` (payment_received)
- **THEN** el primer movimiento tiene `balance_after = 1000`, el segundo `balance_after = 600`, y la cabecera queda en `600`

#### Scenario: El enum incluye la reversa de cobro
- **WHEN** se inspecciona el CHECK de `customer_account_movements.movement_type`
- **THEN** incluye los cinco tipos `sale`, `payment_received`, `payment_received_reversal`, `credit_note` y `adjustment`

#### Scenario: Los movimientos históricos siguen siendo válidos tras ampliar el enum
- **GIVEN** los movimientos de cuenta corriente existentes al momento de la migración
- **WHEN** se amplía el CHECK con `payment_received_reversal`
- **THEN** ninguna fila existente es invalidada ni reescrita
- **AND** la ampliación es idempotente ante una reaplicación de la migración

#### Scenario: El cargo lleva su vencimiento y el cobro no
- **WHEN** se postea un cargo con vencimiento y luego un cobro sobre la misma cuenta
- **THEN** la fila del cargo lleva su `due_date` y la del cobro lo tiene nulo

#### Scenario: Los movimientos históricos quedan sin vencimiento
- **GIVEN** los movimientos existentes al momento de incorporar la columna
- **WHEN** se aplica la migración, incluso dos veces
- **THEN** todas esas filas quedan con vencimiento nulo, ninguna es reescrita y ninguna restricción nueva las invalida

### Requirement: Helper intra-transacción c30_register_customer_account_movement
El sistema SHALL proveer `public.c30_register_customer_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL, p_due_date date DEFAULT NULL) RETURNS uuid` con `SET search_path = public`, **REVOKE de PUBLIC** (callable solo desde RPCs `SECURITY DEFINER`), que **NO abre transacción propia**. El helper SHALL: (a) lockear la fila de cabecera con `SELECT ... FOR UPDATE`; (b) computar `balance_after = balance + p_amount`; (c) INSERT append-only en `customer_account_movements` con `created_by = auth.uid()` y el vencimiento recibido; (d) UPDATE de `customer_accounts.balance`; (e) RETURN el id del movimiento. La acumulación del saldo SHALL usar UPDATE-then-INSERT bajo `FOR UPDATE`, **nunca** `INSERT ... ON CONFLICT DO UPDATE` con delta.

El parámetro de vencimiento SHALL ser **el último y opcional**, de modo que su incorporación no altere la posición de ningún argumento existente. La redefinición SHALL realizarse por baja y alta explícitas de la función —nunca por reemplazo en el lugar con un argumento nuevo con valor por omisión, que dejaría viva la definición anterior como sobrecarga— y los permisos SHALL reafirmarse en el mismo archivo de migración, porque la baja y alta de una función restablece sus permisos.

#### Scenario: el helper serializa con FOR UPDATE sobre la cabecera
- **WHEN** dos movimientos concurrentes sobre la misma cuenta se postean
- **THEN** el lock de fila de cabecera los serializa y cada uno computa `balance_after` sobre el saldo del otro ya commiteado (sin perder ninguno)

#### Scenario: el helper no es callable desde el rol authenticated
- **WHEN** el rol `authenticated` intenta `SELECT c30_register_customer_account_movement(...)`
- **THEN** la llamada es denegada (REVOKE de PUBLIC); solo los RPCs `SECURITY DEFINER` pueden invocarlo

#### Scenario: El vencimiento llega a la fila
- **WHEN** se invoca el helper con un vencimiento
- **THEN** la fila insertada en el ledger lo lleva

#### Scenario: Sin vencimiento el movimiento se postea igual
- **WHEN** se invoca el helper sin informar vencimiento
- **THEN** el movimiento se postea con vencimiento nulo y el saldo se actualiza normalmente

#### Scenario: No queda una definición anterior viva
- **WHEN** se inspecciona el catálogo de funciones tras la migración
- **THEN** existe exactamente una definición del helper, con el argumento de vencimiento

### Requirement: PaymentReceived reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL, p_payment_method_id uuid DEFAULT NULL, p_bank_account_id uuid DEFAULT NULL, p_cash_session_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) **resuelve el `kind` de la forma de pago** consultando el catálogo por `p_payment_method_id` **bajo el `account_id` del tenant**, rechazando con `P0404` la forma de pago inexistente o de otra cuenta, con un mensaje que no revela cuál de los dos casos ocurrió; (c) resuelve o crea la `CustomerAccount` del cliente; (d) aplica idempotencia DEC-06 con `operation_kind = 'payment_received'`; (e) invoca el helper con `amount` negativo (`payment_received` reduce la deuda); (f) inserta una fila en `payments_received` con `payment_method_id`; (g) **rutea el ingreso de fondos por el `kind` derivado**: cuando el `kind` es bancario (`transfer` / `card` / `check` / `wallet`) SHALL delegar en el **helper compartido de movimiento bancario de operaciones** —el mismo que usan la venta, la compra y el gasto— con dirección de ingreso, `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro, obteniendo de él el mapa `kind → movement_type` (`card_settlement` para `card`, `transfer_in` para el resto) y el guard de período conciliado (`P0424`); cuando es `cash` **y se informa `p_cash_session_id`** SHALL invocar el helper intra-transaccional de caja con `amount` positivo, `movement_type = 'payment_received'` y referencia al cobro, sin tocar el ledger bancario; cuando es `cash` **sin** `p_cash_session_id`, o cuando el `kind` es `other`, o cuando no se informa forma de pago, SHALL registrar el cobro sin efecto sobre ningún libro de dinero; (h) emite el evento `PaymentReceived` al outbox con el `kind` derivado y `payment_method_id` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`.

El `kind` NO SHALL aceptarse como dato del cliente: la función NO SHALL contener ninguna enumeración literal de formas de pago. Una forma de pago de `kind = 'credit'` SHALL rechazarse con `P0400`, porque cancelar una cuenta corriente con cuenta corriente es circular.

Un `kind` bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`); esa exigencia SHALL conservarse aunque el helper compartido admita resolver la cuenta desde el destino configurado en la forma de pago, porque un destino sin configurar haría que el helper no escribiera el movimiento **sin levantar error**. Informar `p_cash_session_id` con un `kind` distinto de `cash` SHALL rechazarse con `P0422 cash_optin_requires_cash_kind`, y con una sesión que no esté `open` SHALL rechazarse con `P0422 cash_optin_requires_open_session`; la pertenencia de la sesión a la cuenta la aporta el punto de paso obligado del registro de movimientos de caja. El movimiento de caja SHALL quedar **dentro** del alcance de la clave de idempotencia: un replay SHALL devolver el resultado original sin registrar un segundo movimiento.

`payments_received` SHALL persistir la forma de pago como `payment_method_id` con FK al catálogo, y NO SHALL conservar además una columna de texto con el mismo dato: la baja de una forma de pago es desactivación y preserva la imputación histórica, de modo que la referencia nunca queda colgada y un snapshot de texto sería una segunda fuente de verdad sin consumidor. El parámetro `p_payment_method_id` es **opcional** (`NULL` = sin imputar), y los cobros anteriores a este cambio SHALL permanecer sin imputar, sin backfill. La firma SHALL quedar como **única firma viva** de la función: la firma anterior —con la forma de pago como texto— SHALL eliminarse con `DROP FUNCTION` en la misma migración en lugar de convivir como sobrecarga, y los permisos SHALL re-otorgarse explícitamente porque el `DROP` los resetea. Un cobro que excede el saldo deudor sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar cobro disminuye el saldo
- **WHEN** se registra un `PaymentReceived` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `customer_account_movement` de tipo `payment_received` con `amount = −400` y `balance_after = 600`, y una fila en `payments_received`

#### Scenario: cobro idempotente no duplica
- **WHEN** se llama `rpc_register_payment_received` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo cobro, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si el `kind` es bancario), se inserta un solo `cash_movement` (si se informó sesión de caja) y la segunda llamada devuelve el resultado original (`replayed = true`)

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentReceived` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: sin permiso de escritura es rechazado
- **WHEN** un usuario sin rol owner/admin intenta registrar un cobro
- **THEN** la operación falla con `P0401`

#### Scenario: cobro por transferencia registra movimiento bancario en la misma transacción
- **WHEN** se registra un `PaymentReceived` de 400 imputado a una forma de pago de `kind = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `CustomerAccount` queda en `balance = 600` (con su `customer_account_movement` `payment_received` de `amount = −400`), existe una fila en `payments_received`, y existe un `bank_movement` de `amount = +400`, `movement_type = 'transfer_in'`, `source_doc_type = 'payment_received'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: cobro por billetera virtual registra movimiento bancario
- **WHEN** se registra un `PaymentReceived` imputado a una forma de pago de `kind = 'wallet'` con una cuenta bancaria activa
- **THEN** se crea un `bank_movement` de ingreso con `movement_type = 'transfer_in'` sobre esa cuenta, en el mismo commit
- **AND** el `kind` `wallet` es tratado como bancario igual que en el resto del sistema

#### Scenario: cobro imputado a `other` no toca ningún libro de dinero
- **WHEN** se registra un `PaymentReceived` de 400 imputado a una forma de pago de `kind = 'other'`
- **THEN** el saldo del cliente se reduce a 600 y el cobro queda imputado a esa forma de pago
- **AND** no se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: cobro imputado a cuenta corriente es rechazado
- **WHEN** se registra un `PaymentReceived` imputado a una forma de pago de `kind = 'credit'`
- **THEN** la operación falla con `P0400` y no se inserta ni el cobro, ni el movimiento de cuenta corriente, ni ningún movimiento de dinero

#### Scenario: forma de pago de otro tenant es rechazada
- **WHEN** se registra un `PaymentReceived` informando el identificador de una forma de pago de otra cuenta
- **THEN** la operación falla con `P0404` y no se inserta ninguna fila
- **AND** el mensaje no revela si el identificador existe en otra cuenta

#### Scenario: cobro en efectivo con sesión de caja ingresa al cajón
- **WHEN** se registra un `PaymentReceived` de 400 imputado a `kind = 'cash'` informando una sesión de caja abierta, sobre una cuenta con `balance = 1000`
- **THEN** el saldo del cliente se reduce a 600, existe una fila en `payments_received`, y existe un `cash_movement` de tipo `payment_received` con `amount = +400` y referencia al cobro, todo atómico en un solo commit
- **AND** no se inserta ninguna fila en `bank_movements`

#### Scenario: cobro en efectivo sin sesión de caja no toca ningún libro de dinero
- **WHEN** se registra un `PaymentReceived` de 400 imputado a `kind = 'cash'` sin informar sesión de caja
- **THEN** el saldo del cliente se reduce a 600 y NO se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: sesión de caja con kind no efectivo es rechazada
- **WHEN** se registra un `PaymentReceived` imputado a `kind = 'transfer'` informando una sesión de caja
- **THEN** la operación falla con `P0422 cash_optin_requires_cash_kind` y no se inserta ni el cobro, ni el movimiento de cuenta corriente, ni el movimiento bancario, ni el de caja

#### Scenario: sesión de caja cerrada es rechazada
- **WHEN** se registra un `PaymentReceived` en efectivo informando una sesión de caja que no está `open`
- **THEN** la operación falla con `P0422 cash_optin_requires_open_session` y no se inserta ninguna fila

#### Scenario: kind bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentReceived` imputado a un `kind` bancario y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400` cuando falta la cuenta, `P0412` cuando la cuenta no existe o está inactiva) y no se inserta ni el cobro ni el movimiento bancario
- **AND** la operación NO recae en el destino configurado en la forma de pago

#### Scenario: cobro sin forma de pago imputada
- **WHEN** se invoca `rpc_register_payment_received` sin `p_payment_method_id` ni `p_cash_session_id`
- **THEN** el cobro se registra con la imputación vacía y sin impacto en ningún libro de dinero

#### Scenario: cobro en un período bancario ya conciliado es rechazado
- **GIVEN** una sesión de conciliación cerrada cuyo período incluye la fecha de hoy para una cuenta bancaria
- **WHEN** se registra un `PaymentReceived` por un `kind` bancario contra esa cuenta
- **THEN** la operación falla con `P0424` y no se inserta ni el cobro ni ningún movimiento

#### Scenario: no queda una sobrecarga con la firma anterior
- **WHEN** se inspeccionan las funciones de registro de cobro tras la migración
- **THEN** existe exactamente una definición viva, con la forma de pago como identificador del catálogo, y sus permisos re-otorgados explícitamente
- **AND** no existe ninguna definición que reciba la forma de pago como texto

### Requirement: Toda venta a cuenta corriente postea su cargo, sea cual sea el camino

El sistema SHALL postear el cargo en `customer_account_movements` en **todo** camino de alta de venta cuyo `kind` efectivo de forma de pago sea `credit` —el mostrador (`quickSale`, confirmación de orden de venta) y el formulario de venta por igual—, por el total de la operación, con signo positivo (aumenta la deuda del cliente) y `reference_id` apuntando a la operación de origen. El `kind` SHALL derivarse en el servidor a partir de la forma de pago imputada y NO SHALL aceptarse como dato del cliente. Una venta imputada a `kind = 'credit'` que quede registrada sin su cargo correspondiente SHALL considerarse un defecto, no una configuración válida.

#### Scenario: Venta a crédito desde el formulario postea el cargo

- **GIVEN** un cliente con saldo 0 en su cuenta corriente
- **WHEN** se registra desde el formulario de venta una venta de 12000 imputada a una forma de pago de `kind = 'credit'`
- **THEN** se crea un movimiento de 12000 en `customer_account_movements` con `balance_after = 12000` y `reference_id` = la operación de venta, en el mismo commit

#### Scenario: Venta a crédito desde el formulario emite el evento de cargo

- **WHEN** se registra desde el formulario una venta a crédito de 12000
- **THEN** se inserta en `events` un `CustomerAccountCharged` con el importe, el `customer_account_id`, el `client_id` y la referencia a la operación

#### Scenario: Una venta que no es a crédito no toca la cuenta corriente

- **WHEN** se registra desde el formulario una venta imputada a una forma de pago de `kind = 'cash'`, `transfer`, `card`, `check`, `wallet` u `other`
- **THEN** no se crea ningún movimiento en `customer_account_movements` y el saldo del cliente no cambia

### Requirement: La venta a cuenta corriente exige un cliente identificado

El sistema SHALL rechazar toda venta imputada a una forma de pago de `kind = 'credit'` que no tenga cliente asociado, en cualquier camino de alta, antes de aplicar efectos sobre stock, caja o cuentas corrientes. No hay deuda sin deudor: una venta a cuenta corriente anónima produciría un cargo imposible de cobrar y un saldo huérfano.

#### Scenario: Venta a crédito sin cliente desde el formulario es rechazada

- **WHEN** se registra desde el formulario una venta imputada a `kind = 'credit'` sin cliente seleccionado
- **THEN** la operación falla con `credit_requires_client`, no se descuenta stock y no se crea ninguna venta

#### Scenario: El formulario impide llegar a ese estado

- **WHEN** el usuario elige en el formulario de venta una forma de pago de `kind = 'credit'`
- **THEN** el cliente pasa a ser obligatorio en la superficie y no se puede confirmar la venta sin seleccionarlo

#### Scenario: El formulario muestra el saldo del cliente al vender a crédito

- **GIVEN** un cliente con saldo de 4000 en su cuenta corriente
- **WHEN** el usuario elige una forma de pago de `kind = 'credit'` y selecciona ese cliente en una venta de 1000
- **THEN** la pantalla muestra el saldo actual (4000) y el saldo proyectado tras la venta (5000)

### Requirement: Reversión del cargo de cuenta corriente por borrado de venta
El sistema SHALL registrar un movimiento de tipo `credit_note` por el importe negativo del cargo original cuando se borra una venta que había generado un cargo en la cuenta corriente del cliente, dejando el saldo exactamente en el valor previo a esa venta.

#### Scenario: Venta a crédito impaga
- **WHEN** se borra una venta que cargó la cuenta corriente de un cliente y el cargo sigue impago
- **THEN** se registra un movimiento `credit_note` por el importe negativo del cargo
- **AND** el movimiento referencia la operación borrada
- **AND** el saldo del cliente vuelve exactamente al valor previo a la venta

#### Scenario: Venta sin cargo en cuenta corriente
- **WHEN** se borra una venta que no cargó ninguna cuenta corriente
- **THEN** no se registra ningún movimiento de cuenta corriente

#### Scenario: El ledger permanece append-only
- **WHEN** se compensa el cargo de una venta borrada
- **THEN** el movimiento original permanece en el ledger
- **AND** la compensación se expresa como un movimiento nuevo, no como una baja ni una modificación del original

### Requirement: Rechazo de la reversión que dejaría saldo negativo
El sistema SHALL rechazar el borrado con el código de error `P0425` cuando la reversión del cargo dejaría el saldo de la cuenta corriente por debajo de cero, en lugar de intentar un movimiento que viola el invariante de saldo no negativo del ledger.

#### Scenario: El cliente ya pagó la venta
- **WHEN** se intenta borrar una venta cuyo cargo ya fue cancelado por el cliente
- **THEN** el sistema rechaza el borrado con `P0425`
- **AND** el mensaje indica que debe registrarse primero la devolución del pago
- **AND** no se registra ningún movimiento en la cuenta corriente

#### Scenario: El cliente pagó parcialmente
- **WHEN** se intenta borrar una venta cuyo cargo fue cancelado en parte, de modo que revertirlo dejaría el saldo negativo
- **THEN** el sistema rechaza el borrado con `P0425`

### Requirement: La cuenta corriente de un cliente solo existe dentro del tenant del cliente

El sistema SHALL rechazar toda operación que resuelva, cree o mueva una `CustomerAccount` cuyo `client_id` no pertenezca al `account_id` de la operación, **antes** de insertar o modificar cualquier fila. La validación SHALL vivir en el punto de resolución/creación de la cuenta corriente —el lugar por donde pasan todos los caminos— y no únicamente en cada comando que la invoca, de modo que un camino de alta nuevo nazca cubierto sin acordarse de replicar el guard.

El rechazo SHALL usar el código de error de negocio `P0404`, el mismo que ya usa el camino explícito de creación de cuenta corriente, con un mensaje que nombre el cliente rechazado. La transacción SHALL revertirse entera: no SHALL quedar fila en `customer_accounts`, ni movimiento en `customer_account_movements`, ni cobro en `payments_received`, ni evento en el outbox, ni consumo de la clave de idempotencia.

El motivo no es la fuga de datos —la cuenta corriente del otro tenant queda intacta, porque la fila creada es una fila distinta bajo el `account_id` del atacante— sino la **corrupción del libro propio**: un saldo, sus movimientos y su asiento contable contra una entidad que el tenant nunca va a ver en sus listas de clientes, porque esas sí filtran por cuenta. Un saldo huérfano, imposible de conciliar desde la aplicación.

#### Scenario: Cobro contra un cliente de otro tenant

- **GIVEN** un usuario con permiso de escritura en el tenant A
- **AND** un cliente que pertenece al tenant B
- **WHEN** registra un cobro de 5000 informando el identificador de ese cliente ajeno
- **THEN** la operación falla con `P0404`
- **AND** no queda ninguna fila nueva en `customer_accounts`, `customer_account_movements` ni `payments_received`
- **AND** no se emite ningún evento de cobro

#### Scenario: La clave de idempotencia no se quema en el rechazo

- **GIVEN** un cobro rechazado por cliente ajeno con una clave de idempotencia determinada
- **WHEN** se reintenta la misma clave de idempotencia con un cliente válido del tenant
- **THEN** el cobro se registra normalmente, sin ser tratado como un reintento de la operación fallida

#### Scenario: El cliente propio sigue funcionando igual

- **GIVEN** un cliente del mismo tenant, sin cuenta corriente previa
- **WHEN** se registra una venta a cuenta corriente de 1000 para ese cliente
- **AND** después se registra un cobro de 400
- **THEN** la cuenta corriente se crea en el mismo commit del cargo, con su movimiento y su evento
- **AND** el cobro se registra con su movimiento, su fila de cobro y su evento, dejando el saldo en 600, exactamente como antes del guard

> El cobro no puede ser el primer movimiento de la cuenta: el invariante de
> saldo no negativo lo rechaza con `P0409` antes de llegar a nada de esto. El
> control positivo del camino propio es, necesariamente, cargo y después cobro.

#### Scenario: Las validaciones de payload preceden al guard de parte

- **GIVEN** un cobro cuyo cliente pertenece a otro tenant
- **WHEN** el mismo cobro además informa un importe inválido, o una cuenta bancaria que no existe
- **THEN** el error que llega al usuario es el de la validación de payload —importe inválido o cuenta bancaria no encontrada—, no el de parte no encontrada

> El guard de parte se ubica junto a las demás validaciones de payload y
> **después** de ellas, y **antes** de consumir la clave de idempotencia. El
> orden es observable —determina qué error ve el usuario cuando hay más de un
> problema— así que se especifica en vez de quedar sólo congelado por los
> tests. La regla general: primero se rechaza lo que está mal escrito en el
> pedido, después lo que no pertenece al tenant.

#### Scenario: Un cliente inexistente se rechaza igual que uno ajeno

- **WHEN** se registra un cobro informando un identificador de cliente que no existe en ninguna cuenta
- **THEN** la operación falla con `P0404` y el mensaje no revela si el identificador existe en otro tenant

#### Scenario: El rechazo llega al usuario como "no encontrado"

- **WHEN** el guard rechaza la operación
- **THEN** la API responde `404` con el cuerpo de error estándar de la plataforma, y no un error genérico de servidor

### Requirement: La venta a cuenta corriente exige que el cliente sea del tenant

El sistema SHALL aplicar la misma coherencia de tenencia al cargo automático que produce una venta imputada a una forma de pago de `kind = 'credit'`, por cualquiera de sus caminos —mostrador y formulario de venta—, y no solo al cobro manual. Una venta a crédito con un cliente ajeno SHALL fallar entera: sin venta registrada, sin cargo en la cuenta corriente, sin movimiento de stock y sin evento.

#### Scenario: Venta a crédito desde el formulario con cliente ajeno

- **GIVEN** un usuario del tenant A y un cliente del tenant B
- **WHEN** registra desde el formulario una venta a crédito de 12000 para ese cliente
- **THEN** la operación falla con `P0404`
- **AND** no queda fila en `sales`, ni movimiento en `customer_account_movements`, ni evento en el outbox

#### Scenario: Venta a crédito desde el mostrador con cliente ajeno

- **WHEN** el mismo caso se intenta desde el punto de venta
- **THEN** la operación falla con `P0404` y la orden de venta no queda confirmada

#### Scenario: Venta a crédito con cliente propio no cambia de comportamiento

- **WHEN** se registra una venta a crédito de 12000 para un cliente del propio tenant
- **THEN** el cargo se postea igual que antes: movimiento positivo por el total, cuenta corriente creada si no existía, y evento de cargo emitido

### Requirement: La superficie de cobro ofrece el impacto en caja pre-marcado y explica cuándo no aplica

La interfaz de registro de un cobro de cuenta corriente SHALL ofrecer las formas de pago del **catálogo de la cuenta** a través del componente selector compartido, en el contexto de cobranza, y NO SHALL declarar una lista propia de opciones.

Cuando la forma de pago elegida tiene `kind = 'cash'`, SHALL ofrecer la afirmación del impacto en caja **pre-marcada** si existe una sesión abierta, y SHALL mostrar el motivo concreto cuando no la hay, sin ocultar el bloque en silencio.

El valor inicial marcado es deliberado: cobrar en efectivo es, literalmente, poner plata en el cajón, y el estado previo a este cambio —el cobro que nunca llega al arqueo— se reproduciría si el usuario tuviera que acordarse de marcarlo.

La interfaz SHALL reutilizar la resolución de condiciones compartida que ya emplean los formularios de venta, gasto y compra, adaptando únicamente el texto del motivo; la autoridad sobre la decisión SHALL seguir siendo el servidor. El `kind` que alimenta esa resolución SHALL derivarse de la forma de pago elegida en el catálogo, y NO SHALL inferirse del valor del control de selección: cuando el selector emite un identificador, comparar ese identificador contra la constante de efectivo daría siempre falso y **el bloque de impacto en caja dejaría de ofrecerse sin ningún error visible**. La exigencia de cuenta bancaria para los `kind` bancarios SHALL permanecer.

#### Scenario: Efectivo con caja abierta

- **GIVEN** una sesión de caja abierta en la cuenta
- **WHEN** el usuario elige una forma de pago de `kind = 'cash'` en el modal de cobro
- **THEN** la afirmación de impacto en caja aparece marcada, nombrando la sesión

#### Scenario: Efectivo sin caja abierta

- **GIVEN** ninguna sesión de caja abierta
- **WHEN** el usuario elige una forma de pago de `kind = 'cash'` en el modal de cobro
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta
- **AND** el cobro puede registrarse de todos modos, sin impacto en el arqueo

#### Scenario: El bloque de caja se ofrece con la forma de pago renombrada

- **GIVEN** una forma de pago de `kind = 'cash'` que el usuario renombró a "Caja chica"
- **AND** una sesión de caja abierta
- **WHEN** el usuario la elige en el modal de cobro
- **THEN** la afirmación de impacto en caja aparece marcada igual, porque la condición se evalúa sobre el `kind` y no sobre el nombre ni sobre el identificador

#### Scenario: Método bancario no ofrece el bloque de caja

- **WHEN** el usuario elige una forma de pago de `kind` bancario
- **THEN** el bloque de caja no se muestra y el selector de cuenta bancaria sigue siendo obligatorio

#### Scenario: El selector no ofrece cuenta corriente

- **WHEN** el usuario abre el selector de forma de pago en el modal de cobro
- **THEN** las formas de pago de `kind = 'credit'` no aparecen entre las opciones

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** un cobro en efectivo con sesión abierta
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** el cobro se registra sin movimiento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el modal de cobro se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones
- **AND** el desplegable del selector se despliega dentro del modal con todas sus opciones alcanzables

### Requirement: La anulación de un cobro repone la deuda con un contra-movimiento de tipo propio

El sistema SHALL registrar, al anular un cobro, un movimiento de tipo `payment_received_reversal` por el importe **opuesto exacto** al del cobro anulado, con `reference_id` apuntando al cobro y `created_by` del usuario que anula, dejando el saldo de la cuenta corriente exactamente en el valor que tenía **antes** de ese cobro.

El movimiento del cobro original SHALL permanecer en el ledger sin modificarse: la corrección SHALL expresarse como un movimiento nuevo, nunca como una baja ni una edición del original.

#### Scenario: El saldo vuelve al valor previo al cobro

- **GIVEN** una cuenta en `balance = 1000` sobre la que se registra un cobro de 400, quedando en 600
- **WHEN** se anula ese cobro
- **THEN** existe un movimiento `payment_received_reversal` de `amount = +400` con `balance_after = 1000`
- **AND** la cabecera queda en `balance = 1000`
- **AND** el movimiento `payment_received` de `−400` sigue en el ledger, intacto

#### Scenario: La reversa registra quién anuló

- **WHEN** un usuario anula un cobro
- **THEN** el movimiento de reversa lleva a ese usuario en `created_by`, que puede diferir del que registró el cobro

#### Scenario: La reversa referencia el cobro anulado

- **WHEN** se anula un cobro
- **THEN** el movimiento de reversa lleva el identificador del cobro en `reference_id`

### Requirement: La anulación de un cobro nunca puede violar el invariante de saldo no negativo

El sistema SHALL tratar la anulación de un cobro como una operación que **no puede** dejar el saldo negativo, y SHALL NOT traducir ningún error de saldo a `P0425` en este camino, a diferencia de la reversión de un **cargo**, que sí puede violarlo y por eso lo hace.

La razón es aritmética y estructural: el saldo de la cuenta corriente es la deuda del cliente, un cobro sólo se acepta si no la deja por debajo de cero (`P0409`), y la anulación de ese cobro **suma** el mismo importe. El saldo resultante es siempre mayor o igual al de partida. Un cobro no puede generar saldo a favor, de modo que no existe crédito que el cliente pueda haber consumido y que la anulación necesitaría recuperar.

Esto SHALL declararse explícitamente en lugar de quedar como conocimiento tácito, porque es lo que justifica la ausencia de un guard que el camino hermano sí tiene.

#### Scenario: Anular el cobro que dejó la cuenta en cero

- **GIVEN** una cuenta en `balance = 400` sobre la que se cobra exactamente 400, quedando en 0
- **WHEN** se anula ese cobro
- **THEN** la anulación procede sin error y la cuenta vuelve a `balance = 400`

#### Scenario: El camino de anulación no expone el error de reversión negativa

- **WHEN** se anula cualquier cobro
- **THEN** el sistema no puede responder `P0425`, porque el saldo resultante nunca es menor que el de partida

### Requirement: El historial de cuenta corriente del cliente expone si un cobro es anulable y por qué no lo es

El sistema SHALL derivar en el servidor, para cada movimiento del historial de cuenta corriente, si ofrece la anulación y si esa anulación está bloqueada, y SHALL exponer ambos como datos derivados de la consulta —nunca como columnas denormalizadas del ledger, que quedarían desincronizadas.

Un movimiento SHALL ofrecer la anulación únicamente si es de tipo `payment_received` **y** su documento sigue existiendo en `payments_received`. La anulación SHALL declararse bloqueada cuando el cobro tiene movimiento de caja y no hay sesión abierta en esa caja, evaluado con el **mismo predicado** que aplica el servidor al ejecutar la anulación.

#### Scenario: Un cobro ya anulado deja de ofrecer la acción

- **GIVEN** un cobro que ya fue anulado
- **WHEN** se lista el historial de la cuenta
- **THEN** su movimiento original ya no se marca como anulable, porque su documento no existe

#### Scenario: Un cargo no ofrece la acción

- **WHEN** se lista un movimiento de tipo `sale`, `credit_note`, `adjustment` o `payment_received_reversal`
- **THEN** ninguno se marca como anulable

#### Scenario: El bloqueo derivado coincide con el del servidor

- **GIVEN** un cobro con movimiento de caja y ninguna sesión abierta en esa caja
- **WHEN** se lista el historial y, por separado, se intenta la anulación
- **THEN** el listado lo marca como bloqueado y la anulación falla con `P0426` — el derivado y el guard coinciden

### Requirement: El historial de cuenta corriente nombra la forma de pago configurada

El sistema SHALL exponer, para cada movimiento de tipo `payment_received` del historial de cuenta corriente, el **nombre** de la forma de pago con la que se registró el cobro, resuelto desde el catálogo a través de la imputación del documento, de modo que el usuario lea la etiqueta que él mismo configuró y no un término genérico.

Un movimiento cuyo cobro no tenga forma de pago imputada —los anteriores a este cambio, y los registrados sin imputar— SHALL exponer el dato vacío, y la superficie SHALL omitir la mención en lugar de mostrar un valor inventado. Un movimiento de un tipo distinto de `payment_received` SHALL exponer el dato vacío.

#### Scenario: Cobro imputado muestra el nombre configurado

- **GIVEN** un cobro imputado a una forma de pago que el usuario renombró a "Banco Nación"
- **WHEN** se consulta el historial de cuenta corriente del cliente
- **THEN** el movimiento del cobro expone "Banco Nación"

#### Scenario: Cobro histórico sin imputar

- **GIVEN** un cobro anterior a este cambio, sin forma de pago imputada
- **WHEN** se consulta el historial
- **THEN** el movimiento expone el dato vacío y la superficie no muestra ninguna forma de pago

#### Scenario: Cobro imputado a una forma de pago desactivada

- **GIVEN** un cobro imputado a una forma de pago que después fue dada de baja
- **WHEN** se consulta el historial
- **THEN** el movimiento sigue exponiendo su nombre, porque la baja es desactivación y preserva la imputación histórica

#### Scenario: Movimiento que no es un cobro

- **WHEN** se consulta un movimiento de tipo `sale`, `credit_note`, `adjustment` o una reversa
- **THEN** expone el dato de forma de pago vacío

### Requirement: El historial de cuenta corriente expone el vencimiento y el saldo abierto de cada cargo

El sistema SHALL exponer, para cada movimiento del historial de cuenta corriente de un cliente, su **vencimiento**, si está **vencido**, cuántos **días de atraso** acumula y qué **importe permanece abierto** tras la imputación de cobros.

Esos derivados SHALL calcularse en el servidor, dentro de la consulta que recupera los movimientos, y NO SHALL reimplementarse en la interfaz: la clasificación de vencimiento y la imputación tienen una única definición.

Los derivados SHALL viajar por **todas** las consultas que alimentan el historial, no sólo por la paginada. Una pantalla del historial que se sirva de una consulta distinta quedaría sin el dato aunque los tests unitarios de la otra estuvieran en verde — es un defecto ya ocurrido en este dominio.

Un movimiento que no es un cargo SHALL exponer sus derivados de vencimiento como ausentes, no como cero.

#### Scenario: Un cargo vencido en el historial

- **GIVEN** un cargo de 1000 con vencimiento hace 45 días, cancelado parcialmente por un cobro de 400
- **WHEN** el usuario abre el historial de cuenta corriente del cliente
- **THEN** esa fila muestra su vencimiento, que está vencida, 45 días de atraso y 600 de importe abierto

#### Scenario: Un cobro no tiene vencimiento

- **WHEN** el historial muestra un movimiento de cobro
- **THEN** sus derivados de vencimiento se presentan como ausentes y no como cero

#### Scenario: Todas las consultas del historial traen los derivados

- **WHEN** se recuperan los movimientos de una cuenta corriente por cualquiera de las consultas que alimentan el historial
- **THEN** todas devuelven el vencimiento, el estado de vencimiento, los días de atraso y el importe abierto

#### Scenario: El importe abierto cierra contra el saldo

- **WHEN** se suman los importes abiertos de todos los cargos del historial de una cuenta
- **THEN** el resultado es igual al saldo de esa cuenta corriente

## Implementation Notes

- **Tablas**: `customer_accounts`, `customer_account_movements`, `payments_received` (migración `20260720000001_c30_customer_supplier_accounts.sql`)
- **Helpers**: `c30_register_customer_account_movement` (REVOKE de PUBLIC), `c30_get_or_create_customer_account` (lazy auto-create idempotente vía ON CONFLICT), `_register_bank_movement` (invocado desde `rpc_register_payment_received` para métodos bancarios, C2 `bank-payment-routing`)
- **RPCs**: `rpc_create_customer_account`, `rpc_register_payment_received` (extendida en C2 con `p_payment_method`/`p_bank_account_id`) — ambos SECURITY DEFINER, REVOKE de PUBLIC/anon + GRANT a authenticated
- **RLS**: solo política SELECT en las 3 tablas (`account_id IN (SELECT current_account_ids())`); escritura append-only via RPC definer
- **Integración C-29**: `_c29_confirm_order_core` (C-29) llama `c30_register_customer_account_movement` para `payment_method='credit'`; `CHECK (payment_method IN ('cash','other','credit'))` en `sales_orders` ampliado en C-30
- **Backend**: `backend/schemas/customer_accounts.py`, `backend/repositories/customer_account_repository.py`, `backend/services/customer_accounts.py`, `backend/routers/customer_accounts.py`
- **Frontend**: `frontend/app/(dashboard)/clientes/[id]/cuenta/page.tsx` con Server Component + hooks React Query
- **Smoke prod**: 2026-06-20 — migración `20260720000001` + hotfix `20260720000002` LIVE; 7/7 smoke cases OK
- **C2 bank-payment-routing** (2026-07-02, PR #249): `rpc_register_payment_received` rutea cobros bancarios a `bank_movements` vía `_register_bank_movement`; migración `20260804000007_bank_payment_routing.sql`. Ver `bank-movement` spec.
