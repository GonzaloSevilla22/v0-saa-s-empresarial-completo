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
El sistema SHALL proveer un ledger `customer_account_movements` (`id`, `customer_account_id` FK→`customer_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `sale|payment_received|credit_note|adjustment`, `reference_id uuid` nullable, `created_by`, `created_at`). El ledger SHALL ser **append-only**: la RLS SHALL tener únicamente política SELECT (sin UPDATE ni DELETE). Cada movimiento SHALL persistir su `balance_after` (saldo de la cuenta tras aplicar el movimiento). El `balance_after` SHALL computarse a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

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

### Requirement: Helper intra-transacción c30_register_customer_account_movement
El sistema SHALL proveer `public.c30_register_customer_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL) RETURNS uuid` con `SET search_path = public`, **REVOKE de PUBLIC** (callable solo desde RPCs `SECURITY DEFINER`), que **NO abre transacción propia**. El helper SHALL: (a) lockear la fila de cabecera con `SELECT ... FOR UPDATE`; (b) computar `balance_after = balance + p_amount`; (c) INSERT append-only en `customer_account_movements` con `created_by = auth.uid()`; (d) UPDATE de `customer_accounts.balance`; (e) RETURN el id del movimiento. La acumulación del saldo SHALL usar UPDATE-then-INSERT bajo `FOR UPDATE`, **nunca** `INSERT ... ON CONFLICT DO UPDATE` con delta.

#### Scenario: el helper serializa con FOR UPDATE sobre la cabecera
- **WHEN** dos movimientos concurrentes sobre la misma cuenta se postean
- **THEN** el lock de fila de cabecera los serializa y cada uno computa `balance_after` sobre el saldo del otro ya commiteado (sin perder ninguno)

#### Scenario: el helper no es callable desde el rol authenticated
- **WHEN** el rol `authenticated` intenta `SELECT c30_register_customer_account_movement(...)`
- **THEN** la llamada es denegada (REVOKE de PUBLIC); solo los RPCs `SECURITY DEFINER` pueden invocarlo

### Requirement: PaymentReceived reduce el saldo en la misma transacción
El sistema SHALL proveer `rpc_register_payment_received(p_idempotency_key text, p_client_id uuid, p_amount numeric, p_reference_sale_id uuid DEFAULT NULL, p_payment_method text DEFAULT 'cash', p_bank_account_id uuid DEFAULT NULL, p_cash_session_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que, en una sola transacción: (a) valida `is_account_writer` (sino `P0401`) y `amount > 0` (sino `P0400`); (b) resuelve o crea la `CustomerAccount` del cliente; (c) aplica idempotencia DEC-06 con `operation_kind = 'payment_received'`; (d) invoca el helper con `amount` negativo (`payment_received` reduce la deuda); (e) inserta una fila en `payments_received`; (f) **rutea el ingreso de fondos por método de pago**: cuando `p_payment_method` es un método bancario (`transfer` / `card` / `check`) SHALL invocar `_register_bank_movement` en la misma transacción con `amount` positivo (ingreso), `movement_type` derivado (`transfer_in` para transfer/check, `card_settlement` para card), `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro; cuando es `cash` **y se informa `p_cash_session_id`** SHALL invocar el helper intra-transaccional de caja con `amount` positivo, `movement_type = 'payment_received'` y referencia al cobro, sin tocar el ledger bancario; cuando es `cash` **sin** `p_cash_session_id` SHALL registrar el cobro sin efecto sobre ningún libro de dinero; (g) emite el evento `PaymentReceived` al outbox con `payment_method` (y `bank_account_id` cuando aplique) en el payload, para que el posteo contable async (`journal-entry`) rutee la contrapartida a `1110 Banco` vs `1100 Caja`.

Un método bancario SHALL exigir un `p_bank_account_id` válido y activo (sino `P0412`/`P0400`). Informar `p_cash_session_id` con un método distinto de `cash` SHALL rechazarse con `P0422 cash_optin_requires_cash_kind`, y con una sesión que no esté `open` SHALL rechazarse con `P0422 cash_optin_requires_open_session`; la pertenencia de la sesión a la cuenta la aporta el punto de paso obligado del registro de movimientos de caja. El movimiento de caja SHALL quedar **dentro** del alcance de la clave de idempotencia: un replay SHALL devolver el resultado original sin registrar un segundo movimiento.

Los parámetros `p_payment_method`, `p_bank_account_id` y `p_cash_session_id` son **aditivos y opcionales con default retrocompatible** (`cash`/`NULL`/`NULL`): las firmas y llamadas previas siguen funcionando y conservan su comportamiento —un cobro en efectivo sin sesión informada no toca ningún libro, exactamente como antes de este cambio. La firma extendida SHALL quedar como **única firma viva** de la función: la firma anterior SHALL eliminarse en la misma migración en lugar de convivir como sobrecarga. Un cobro que excede el saldo deudor sin marca de anticipo SHALL fallar con `P0409`.

#### Scenario: registrar cobro disminuye el saldo
- **WHEN** se registra un `PaymentReceived` de 400 sobre una cuenta con `balance = 1000`
- **THEN** la cuenta queda en `balance = 600`, existe un `customer_account_movement` de tipo `payment_received` con `amount = −400` y `balance_after = 600`, y una fila en `payments_received`

#### Scenario: cobro idempotente no duplica
- **WHEN** se llama `rpc_register_payment_received` dos veces con la misma `idempotency_key`
- **THEN** se registra un solo cobro, el saldo se reduce una sola vez, se inserta un solo `bank_movement` (si es método bancario), se inserta un solo `cash_movement` (si se informó sesión de caja) y la segunda llamada devuelve el resultado original (`replayed = true`)

#### Scenario: monto no positivo es rechazado
- **WHEN** se registra un `PaymentReceived` con `amount = 0` o negativo
- **THEN** la operación falla con `P0400`

#### Scenario: sin permiso de escritura es rechazado
- **WHEN** un usuario sin rol owner/admin intenta registrar un cobro
- **THEN** la operación falla con `P0401`

#### Scenario: cobro por transferencia registra movimiento bancario en la misma transacción
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'transfer'` y una `bank_account_id` activa, sobre una cuenta con `balance = 1000`
- **THEN** la `CustomerAccount` queda en `balance = 600` (con su `customer_account_movement` `payment_received` de `amount = −400`), existe una fila en `payments_received`, y existe un `bank_movement` de `amount = +400`, `movement_type = 'transfer_in'`, `source_doc_type = 'payment_received'` sobre la cuenta bancaria indicada, todo atómico en un solo commit

#### Scenario: cobro en efectivo con sesión de caja ingresa al cajón
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'cash'` informando una sesión de caja abierta, sobre una cuenta con `balance = 1000`
- **THEN** el saldo del cliente se reduce a 600, existe una fila en `payments_received`, y existe un `cash_movement` de tipo `payment_received` con `amount = +400` y referencia al cobro, todo atómico en un solo commit
- **AND** no se inserta ninguna fila en `bank_movements`

#### Scenario: cobro en efectivo sin sesión de caja no toca ningún libro de dinero
- **WHEN** se registra un `PaymentReceived` de 400 con `payment_method = 'cash'` sin informar sesión de caja
- **THEN** el saldo del cliente se reduce a 600 y NO se inserta ninguna fila en `bank_movements` ni en `cash_movements`

#### Scenario: sesión de caja con método no efectivo es rechazada
- **WHEN** se registra un `PaymentReceived` con `payment_method = 'transfer'` informando una sesión de caja
- **THEN** la operación falla con `P0422 cash_optin_requires_cash_kind` y no se inserta ni el cobro, ni el movimiento de cuenta corriente, ni el movimiento bancario, ni el de caja

#### Scenario: sesión de caja cerrada es rechazada
- **WHEN** se registra un `PaymentReceived` en efectivo informando una sesión de caja que no está `open`
- **THEN** la operación falla con `P0422 cash_optin_requires_open_session` y no se inserta ninguna fila

#### Scenario: método bancario sin cuenta bancaria es rechazado
- **WHEN** se registra un `PaymentReceived` con `payment_method = 'transfer'` y `bank_account_id` nulo o inexistente/inactiva
- **THEN** la operación falla (`P0400` cuando falta la cuenta, `P0412` cuando la cuenta no existe o está inactiva) y no se inserta ni el cobro ni el movimiento bancario

#### Scenario: cobro sin payment_method usa el default retrocompatible
- **WHEN** un llamador previo invoca `rpc_register_payment_received` sin `p_payment_method` ni `p_cash_session_id`
- **THEN** la operación se comporta como `cash` sin impacto en libros de dinero — la firma extendida no rompe a los llamadores existentes

#### Scenario: no queda una sobrecarga con la firma anterior
- **WHEN** se inspeccionan las funciones de registro de cobro tras la migración
- **THEN** existe exactamente una definición viva, con la firma extendida y sus permisos re-otorgados explícitamente

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

La interfaz de registro de un cobro de cuenta corriente SHALL ofrecer, cuando el método de pago elegido es efectivo, la afirmación del impacto en caja **pre-marcada** si existe una sesión abierta, y SHALL mostrar el motivo concreto cuando no la hay, sin ocultar el bloque en silencio.

El valor inicial marcado es deliberado: cobrar en efectivo es, literalmente, poner plata en el cajón, y el estado previo a este cambio —el cobro que nunca llega al arqueo— se reproduciría si el usuario tuviera que acordarse de marcarlo.

La interfaz SHALL reutilizar la resolución de condiciones compartida que ya emplean los formularios de venta, gasto y compra, adaptando únicamente el texto del motivo; la autoridad sobre la decisión SHALL seguir siendo el servidor. El selector de método de pago y la exigencia de cuenta bancaria para los métodos bancarios SHALL permanecer sin cambios.

#### Scenario: Efectivo con caja abierta

- **GIVEN** una sesión de caja abierta en la cuenta
- **WHEN** el usuario elige "Efectivo" en el modal de cobro
- **THEN** la afirmación de impacto en caja aparece marcada, nombrando la sesión

#### Scenario: Efectivo sin caja abierta

- **GIVEN** ninguna sesión de caja abierta
- **WHEN** el usuario elige "Efectivo" en el modal de cobro
- **THEN** el bloque aparece igual, sin control de afirmación, explicando que no hay caja abierta
- **AND** el cobro puede registrarse de todos modos, sin impacto en el arqueo

#### Scenario: Método bancario no ofrece el bloque de caja

- **WHEN** el usuario elige transferencia, tarjeta o cheque
- **THEN** el bloque de caja no se muestra y el selector de cuenta bancaria sigue siendo obligatorio

#### Scenario: El usuario desmarca la afirmación

- **GIVEN** un cobro en efectivo con sesión abierta
- **WHEN** el usuario desmarca la afirmación y confirma
- **THEN** el cobro se registra sin movimiento de caja

#### Scenario: Presentación responsive y por tema

- **WHEN** el modal de cobro se muestra en escritorio o en móvil, en tema claro u oscuro
- **THEN** usa los tokens semánticos del design system
- **AND** es legible y operable en las cuatro combinaciones

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
