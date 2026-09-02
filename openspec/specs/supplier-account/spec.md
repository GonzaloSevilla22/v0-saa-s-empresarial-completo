# supplier-account

> Synced from change `v21-customer-supplier-accounts` (C-30) — 2026-06-20

## Purpose

Cuentas corrientes de proveedores: espejo simétrico de `customer-account` en la capa de proveedores. `SupplierAccount` materializa cuánto se le debe al proveedor; integra ledger append-only `supplier_account_movements` para compras a crédito manuales, pagos idempotentes y ajustes. La integración con el flujo de compras de stock es manual (OQ-3 opción B): `rpc_create_purchase_operation` no toca la cta cte automáticamente.
## Requirements
### Requirement: Agregado SupplierAccount con saldo materializado
El sistema SHALL proveer un agregado `SupplierAccount` (tabla `supplier_accounts`) con `id`, `account_id` (tenancy, FK→`accounts`), `supplier_id` (FK→`suppliers`), `balance numeric(15,2) NOT NULL DEFAULT 0` (saldo materializado: lo que se le debe al proveedor), `created_by`, `created_at`. SHALL existir a lo sumo **una** `SupplierAccount` por `(account_id, supplier_id)` (UNIQUE). Toda la escritura del agregado SHALL ocurrir vía RPC `SECURITY DEFINER`; la RLS de lectura SHALL ser `account_id IN (SELECT public.current_account_ids())`.

El par `(account_id, supplier_id)` SHALL ser **coherente**: el `supplier_id` SHALL pertenecer al `account_id` de la propia fila. La clave foránea a `suppliers` no expresa esa restricción por sí sola, así que la coherencia SHALL garantizarse en la resolución/creación de la cuenta corriente, que es el único camino de escritura del agregado. Una `SupplierAccount` cuyo proveedor pertenece a otro tenant SHALL considerarse un defecto de datos, no una configuración válida.

#### Scenario: crear cuenta corriente de un proveedor
- **WHEN** se crea una `SupplierAccount` para un proveedor de la cuenta
- **THEN** existe una fila en `supplier_accounts` con `balance = 0` y `(account_id, supplier_id)` único

#### Scenario: una sola cuenta por proveedor
- **WHEN** se intenta crear una segunda `SupplierAccount` para el mismo `(account_id, supplier_id)`
- **THEN** la operación es idempotente y devuelve la cuenta existente

#### Scenario: RLS por cuenta en lectura
- **WHEN** un usuario consulta `supplier_accounts`
- **THEN** solo ve las cuentas cuyo `account_id` pertenece a su cuenta

#### Scenario: no existe cuenta corriente con proveedor de otro tenant
- **WHEN** se recorre `supplier_accounts` uniendo cada fila con su proveedor
- **THEN** no existe ninguna fila cuyo `suppliers.account_id` difiera del `supplier_accounts.account_id`

### Requirement: Ledger append-only de movimientos del proveedor con balance_after
El sistema SHALL proveer un ledger `supplier_account_movements` (`id`, `supplier_account_id` FK→`supplier_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `purchase|payment_made|payment_made_reversal|debit_note|adjustment`, `reference_id uuid` nullable, `created_by`, `created_at`). El ledger SHALL ser **append-only** (RLS solo SELECT, sin UPDATE/DELETE). Cada movimiento SHALL persistir su `balance_after`, computado a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

El tipo `payment_made_reversal` SHALL designar la anulación de un pago a proveedor y SHALL postearse con importe **positivo** (repone la deuda con el proveedor). SHALL ser un tipo propio y SHALL NOT reutilizarse `debit_note`, que designa la reversión de un **cargo** y se postea negativo, ni `adjustment`, reservado a la corrección manual.

La ampliación del CHECK SHALL ser aditiva e idempotente: ninguna fila existente SHALL ser invalidada ni reescrita.

#### Scenario: movimiento persiste balance_after
- **WHEN** se postea un movimiento de `amount = 1000` (purchase) sobre una cuenta con `balance = 0`
- **THEN** la fila del ledger tiene `balance_after = 1000` y la cabecera `supplier_accounts.balance` queda en `1000`

#### Scenario: ledger es append-only
- **WHEN** un usuario intenta UPDATE o DELETE sobre `supplier_account_movements`
- **THEN** la operación es denegada por RLS

#### Scenario: movement_type fuera del dominio es rechazado
- **WHEN** se intenta insertar un movimiento con `movement_type = 'sale'` (tipo de cliente, no de proveedor)
- **THEN** el CHECK rechaza la fila (`check_violation`)

#### Scenario: El enum incluye la reversa de pago
- **WHEN** se inspecciona el CHECK de `supplier_account_movements.movement_type`
- **THEN** incluye los cinco tipos `purchase`, `payment_made`, `payment_made_reversal`, `debit_note` y `adjustment`

#### Scenario: Los movimientos históricos siguen siendo válidos tras ampliar el enum
- **GIVEN** los movimientos de cuenta corriente de proveedor existentes al momento de la migración
- **WHEN** se amplía el CHECK con `payment_made_reversal`
- **THEN** ninguna fila existente es invalidada ni reescrita
- **AND** la ampliación es idempotente ante una reaplicación de la migración

### Requirement: Helper intra-transacción c30_register_supplier_account_movement
El sistema SHALL proveer `public.c30_register_supplier_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL) RETURNS uuid` con `SET search_path = public`, **REVOKE de PUBLIC**, que **NO abre transacción propia**, espejo exacto de `c30_register_customer_account_movement`: lock de cabecera con `FOR UPDATE`, `balance_after = balance + p_amount`, INSERT append-only, UPDATE de la cabecera, RETURN id. La acumulación SHALL usar UPDATE-then-INSERT, nunca `ON CONFLICT DO UPDATE` con delta.

#### Scenario: el helper serializa con FOR UPDATE
- **WHEN** dos movimientos concurrentes sobre la misma `SupplierAccount` se postean
- **THEN** el lock de cabecera los serializa y ambos quedan reflejados en el saldo final

#### Scenario: el helper no es callable desde authenticated
- **WHEN** el rol `authenticated` intenta invocar el helper directamente
- **THEN** la llamada es denegada (REVOKE de PUBLIC)

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

### Requirement: Toda compra a cuenta corriente postea su cargo

El sistema SHALL postear el cargo en `supplier_account_movements` en **todo** camino de alta de compra cuyo `kind` efectivo de forma de pago sea `credit`, por el total de la operación, con signo positivo (aumenta lo que se le debe al proveedor) y `reference_id` apuntando al `operation_id` de la compra. El `kind` SHALL derivarse en el servidor a partir de la forma de pago imputada y NO SHALL aceptarse como dato del cliente.

El disparo SHALL usar el `kind` **crudo** derivado de la forma de pago, y NO el valor por defecto que el evento contable aplica cuando no hay forma de pago imputada: una compra **sin forma de pago** SHALL propagarse como `credit` hacia la partida doble (comportamiento vigente e histórico) y, al mismo tiempo, NO SHALL postear ningún movimiento en la cuenta corriente del proveedor. Solo la imputación **explícita** a una forma de pago de `kind = 'credit'` genera deuda observable en el ledger operativo.

Una compra imputada a `kind = 'credit'` que quede registrada sin su cargo correspondiente SHALL considerarse un defecto, no una configuración válida.

#### Scenario: Compra a crédito postea el cargo

- **GIVEN** un proveedor sin cuenta corriente previa
- **WHEN** se registra desde el formulario de compra una compra de 8000 imputada a una forma de pago de `kind = 'credit'` para ese proveedor
- **THEN** se crea la `supplier_accounts` del proveedor y un movimiento de tipo `purchase` por 8000 con `balance_after = 8000` y `reference_id` = la operación de compra, en el mismo commit

#### Scenario: Compra a crédito emite el evento de cargo

- **WHEN** se registra una compra a crédito de 8000
- **THEN** se inserta en `events` un `SupplierAccountCharged` con el importe, el `supplier_account_id`, el `supplier_id` y la referencia a la operación

#### Scenario: Compra en efectivo no toca la cuenta corriente

- **WHEN** se registra una compra imputada a una forma de pago de `kind = 'cash'`, `transfer`, `card`, `check`, `wallet` u `other`
- **THEN** no se crea ningún movimiento en `supplier_account_movements` y el saldo del proveedor no cambia

#### Scenario: Compra sin forma de pago imputada no toca la cuenta corriente

- **WHEN** se registra una compra sin informar forma de pago, con o sin proveedor
- **THEN** no se crea ningún movimiento en `supplier_account_movements`, y el evento contable emitido conserva su valor por defecto `credit`

#### Scenario: Un fallo posterior al cargo revierte la compra entera

- **GIVEN** una compra a crédito en curso cuyo cargo ya fue posteado
- **WHEN** un paso posterior de la misma transacción falla
- **THEN** ni las filas de `purchases`, ni el movimiento de cuenta corriente, ni el evento quedan persistidos

### Requirement: La compra a cuenta corriente exige un proveedor identificado

El sistema SHALL rechazar toda compra imputada a una forma de pago de `kind = 'credit'` que no tenga proveedor asociado, **antes** de aplicar efectos sobre stock, banco o cuentas corrientes. No hay deuda sin acreedor: una compra a cuenta corriente anónima produciría un pasivo imposible de cancelar y un saldo huérfano. El rechazo SHALL usar el mismo código de error de negocio que el rechazo simétrico de la venta a crédito sin cliente.

El sistema SHALL además validar que el proveedor informado pertenezca a la cuenta y no esté borrado, rechazando la operación en caso contrario.

#### Scenario: Compra a crédito sin proveedor es rechazada

- **WHEN** se registra una compra imputada a `kind = 'credit'` sin proveedor
- **THEN** la operación falla con `credit_requires_supplier`, no se modifica stock y no se crea ninguna fila de compra

#### Scenario: El formulario impide llegar a ese estado

- **WHEN** el usuario elige en el formulario de compra una forma de pago de `kind = 'credit'`
- **THEN** el proveedor pasa a ser obligatorio en la superficie y no se puede confirmar la compra sin seleccionarlo

#### Scenario: El formulario muestra el saldo del proveedor al comprar a crédito

- **GIVEN** un proveedor con saldo de 5000 en su cuenta corriente
- **WHEN** el usuario elige una forma de pago de `kind = 'credit'` y selecciona ese proveedor en una compra de 2000
- **THEN** la pantalla muestra el saldo actual (5000) y el saldo proyectado tras la compra (7000)

#### Scenario: Proveedor de otra cuenta o borrado es rechazado

- **WHEN** se registra una compra informando un proveedor inexistente, de otra cuenta, o con `deleted_at` seteado
- **THEN** la operación es rechazada y no se registra ni la compra ni ningún cargo

### Requirement: La compra con cargo posteado es inmutable y se corrige por borrado

El sistema SHALL impedir la edición de una operación de compra que tenga un movimiento posteado en la cuenta corriente del proveedor, con el mismo código de conflicto de estado que usa para las demás operaciones con dinero posteado, y SHALL exponer ese bloqueo en la superficie **antes** de que el usuario intente editar. El camino de corrección SHALL ser el borrado de la operación, que compensa el cargo, el movimiento bancario y el stock de forma atómica.

#### Scenario: Editar una compra a crédito es rechazado

- **GIVEN** una compra a crédito con su cargo posteado en la cuenta corriente del proveedor
- **WHEN** se intenta editar la operación
- **THEN** la operación es rechazada con el conflicto de estado y el mensaje nombra el camino de corrección

#### Scenario: El listado de compras deshabilita la edición con motivo visible

- **GIVEN** una compra con cargo de cuenta corriente posteado
- **WHEN** el usuario consulta el listado de operaciones de compra
- **THEN** la acción de editar aparece deshabilitada con el motivo visible, sin necesidad de llegar al error del servidor

#### Scenario: Borrar la compra devuelve el saldo del proveedor a su valor previo

- **GIVEN** un proveedor cuyo saldo pasó de 0 a 8000 por una compra a crédito
- **WHEN** se borra esa operación de compra
- **THEN** se registra el movimiento de reversión, el saldo vuelve a 0, el movimiento original permanece en el ledger, y el stock queda repuesto

### Requirement: Cargo manual de compra a crédito en cta cte de proveedor
El sistema SHALL proveer `rpc_register_supplier_charge(p_idempotency_key text, p_supplier_id uuid, p_amount numeric, p_reference_id uuid DEFAULT NULL) RETURNS jsonb` (`SECURITY DEFINER`) que postea un movimiento de tipo `purchase` (`amount` positivo) en la `SupplierAccount`, incrementando lo que se le debe al proveedor. Es el camino **manual y complementario**: sirve para cargar deuda con un proveedor que no nace de una operación de compra registrada en el sistema (saldos iniciales, servicios, ajustes de alta), y convive con el camino automático del alta de compra a crédito.

**Deroga la decisión OQ-3/opción B de C-30**: el flujo de compras de stock ya NO es ajeno a la cuenta corriente. Desde `compras-proveedor-cuenta-corriente`, `rpc_create_purchase_operation` postea el cargo automáticamente cuando la forma de pago imputada es de `kind = 'credit'`, vía el helper compartido de cargo de tercero. La decisión original se tomó cuando el catálogo de formas de pago no existía y la compra no tenía forma de expresar "a crédito".

#### Scenario: cargar compra a crédito aumenta el saldo del proveedor
- **WHEN** se registra un cargo de 1500 sobre la `SupplierAccount` de un proveedor con `balance = 0`
- **THEN** la cuenta queda en `balance = 1500` con un movimiento de tipo `purchase`, `amount = +1500`, `balance_after = 1500`

#### Scenario: el flujo de compras de stock postea el cargo cuando la forma de pago es de cuenta corriente
- **WHEN** se crea una compra de stock vía `rpc_create_purchase_operation` imputada a una forma de pago de `kind = 'credit'`, con proveedor
- **THEN** se crea un `supplier_account_movement` de tipo `purchase` por el total, en el mismo commit que el alta de la compra

#### Scenario: el flujo de compras de stock no postea nada cuando la forma de pago no es de cuenta corriente
- **WHEN** se crea una compra de stock vía `rpc_create_purchase_operation` sin forma de pago imputada, o imputada a un `kind` distinto de `credit`
- **THEN** no se crea ningún `supplier_account_movement`

#### Scenario: el cargo manual y el automático comparten ledger y semántica
- **WHEN** se comparan un cargo posteado manualmente y uno posteado por el alta de una compra a crédito
- **THEN** ambos son movimientos de tipo `purchase` con signo positivo sobre la misma `SupplierAccount`, con `balance_after` calculado por el mismo helper

### Requirement: La cuenta corriente de un proveedor solo existe dentro del tenant del proveedor

El sistema SHALL rechazar toda operación que resuelva, cree o mueva una `SupplierAccount` cuyo `supplier_id` no pertenezca al `account_id` de la operación, **antes** de insertar o modificar cualquier fila. Espejo exacto del guard del lado cliente: la validación SHALL vivir en el punto de resolución/creación de la cuenta corriente, de modo que cubra por igual el pago manual, el cargo manual y el cargo automático de una compra a crédito, presentes y futuros.

El rechazo SHALL usar el código de error de negocio `P0404`, el mismo del camino explícito de creación de cuenta corriente de proveedor, con un mensaje que nombre el proveedor rechazado. La transacción SHALL revertirse entera: no SHALL quedar fila en `supplier_accounts`, ni movimiento en `supplier_account_movements`, ni pago en `payments_made`, ni evento en el outbox, ni consumo de la clave de idempotencia.

#### Scenario: Pago a un proveedor de otro tenant

- **GIVEN** un usuario con permiso de escritura en el tenant A
- **AND** un proveedor que pertenece al tenant B
- **WHEN** registra un pago de 8000 informando el identificador de ese proveedor ajeno
- **THEN** la operación falla con `P0404`
- **AND** no queda ninguna fila nueva en `supplier_accounts`, `supplier_account_movements` ni `payments_made`
- **AND** no se emite ningún evento de pago

#### Scenario: Cargo manual contra un proveedor de otro tenant

- **WHEN** se registra un cargo manual de 8000 contra un proveedor ajeno
- **THEN** la operación falla con `P0404` y no se crea ni la cuenta corriente ni el movimiento ni el evento de cargo

#### Scenario: El proveedor propio sigue funcionando igual

- **GIVEN** un proveedor del mismo tenant, sin cuenta corriente previa
- **WHEN** se registra un cargo manual de 8000
- **THEN** la cuenta corriente se crea en el mismo commit, el movimiento queda con `balance_after = 8000` y el evento de cargo se emite, exactamente como antes del guard

#### Scenario: Las validaciones de payload preceden al guard de parte

- **GIVEN** un pago o un cargo manual cuyo proveedor pertenece a otro tenant
- **WHEN** la misma operación además informa un importe inválido
- **THEN** el error que llega al usuario es el de la validación de payload, no el de parte no encontrada
- **AND** en el caso del **pago**, que es el único que recibe cuenta bancaria, lo mismo vale si informa una cuenta bancaria que no existe

> Espejo exacto del lado cliente: el guard de parte va después del resto de
> las validaciones de payload y antes de consumir la clave de idempotencia.
> El orden es observable, así que se especifica.
>
> La cuenta bancaria sólo aplica al pago: el cargo manual no la recibe entre
> sus parámetros, así que de ese camino sólo se puede especificar —y
> verificar— el orden contra el importe.

#### Scenario: Un proveedor inexistente se rechaza igual que uno ajeno

- **WHEN** se registra un pago informando un identificador de proveedor que no existe en ninguna cuenta
- **THEN** la operación falla con `P0404` y el mensaje no revela si el identificador existe en otro tenant

#### Scenario: El rechazo llega al usuario como "no encontrado"

- **WHEN** el guard rechaza la operación
- **THEN** la API responde `404` con el cuerpo de error estándar de la plataforma, y no un error genérico de servidor

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

### Requirement: La anulación de un pago a proveedor repone la deuda con un contra-movimiento de tipo propio

El sistema SHALL registrar, al anular un pago a proveedor, un movimiento de tipo `payment_made_reversal` por el importe **opuesto exacto** al del pago anulado, con `reference_id` apuntando al pago y `created_by` del usuario que anula, dejando el saldo exactamente en el valor que tenía **antes** de ese pago.

El movimiento del pago original SHALL permanecer en el ledger sin modificarse.

#### Scenario: El saldo vuelve al valor previo al pago

- **GIVEN** una cuenta de proveedor en `balance = 1000` sobre la que se registra un pago de 400, quedando en 600
- **WHEN** se anula ese pago
- **THEN** existe un movimiento `payment_made_reversal` de `amount = +400` con `balance_after = 1000`
- **AND** la cabecera queda en `balance = 1000`
- **AND** el movimiento `payment_made` de `−400` sigue en el ledger, intacto

#### Scenario: La reversa registra quién anuló y a qué pago corresponde

- **WHEN** un usuario anula un pago a proveedor
- **THEN** el movimiento de reversa lleva a ese usuario en `created_by` y el identificador del pago en `reference_id`

### Requirement: La anulación de un pago a proveedor nunca puede violar el invariante de saldo no negativo

El sistema SHALL tratar la anulación de un pago a proveedor como una operación que **no puede** dejar el saldo negativo, y SHALL NOT traducir ningún error de saldo a `P0425` en este camino, por el mismo razonamiento aritmético que rige para el cobro de cliente: el saldo es la deuda con el proveedor, el pago sólo se acepta si no la deja por debajo de cero, y la anulación **suma** el mismo importe.

#### Scenario: Anular el pago que dejó la cuenta en cero

- **GIVEN** una cuenta de proveedor en `balance = 400` sobre la que se paga exactamente 400, quedando en 0
- **WHEN** se anula ese pago
- **THEN** la anulación procede sin error y la cuenta vuelve a `balance = 400`

### Requirement: El historial de cuenta corriente del proveedor expone si un pago es anulable y por qué no lo es

El sistema SHALL derivar en el servidor, para cada movimiento del historial de cuenta corriente de proveedor, si ofrece la anulación y si está bloqueada, con el mismo criterio y el mismo carácter derivado que el historial de cliente: la acción SHALL ofrecerse únicamente sobre un movimiento de tipo `payment_made` cuyo documento sigue existiendo en `payments_made`, y SHALL declararse bloqueada cuando el pago tiene movimiento de caja y no hay sesión abierta en esa caja.

#### Scenario: Un pago ya anulado deja de ofrecer la acción

- **GIVEN** un pago a proveedor que ya fue anulado
- **WHEN** se lista el historial de la cuenta
- **THEN** su movimiento original ya no se marca como anulable

#### Scenario: Un cargo de compra no ofrece la acción

- **WHEN** se lista un movimiento de tipo `purchase`, `debit_note`, `adjustment` o `payment_made_reversal`
- **THEN** ninguno se marca como anulable

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

## Implementation Notes

- **Tablas**: `supplier_accounts`, `supplier_account_movements`, `payments_made` (migración `20260720000001_c30_customer_supplier_accounts.sql`)
- **Helpers**: `c30_register_supplier_account_movement` (REVOKE de PUBLIC), `c30_get_or_create_supplier_account` (lazy auto-create idempotente), `_register_bank_movement` (invocado desde `rpc_register_payment_made` para métodos bancarios, C2 `bank-payment-routing`)
- **RPCs**: `rpc_create_supplier_account`, `rpc_register_payment_made` (extendida en C2 con `p_payment_method`/`p_bank_account_id`), `rpc_register_supplier_charge` — todos SECURITY DEFINER
- **RLS**: solo política SELECT en las 3 tablas (`account_id IN (SELECT current_account_ids())`); escritura solo vía RPC definer
- **Decisión OQ-3**: integración con compras de stock es MANUAL (opción B) — `rpc_create_purchase_operation` no toca la cta cte automáticamente
- **Backend**: `backend/schemas/supplier_accounts.py`, `backend/repositories/supplier_account_repository.py`, `backend/services/supplier_accounts.py`, `backend/routers/supplier_accounts.py`
- **Frontend**: `frontend/app/(dashboard)/proveedores/[id]/cuenta/page.tsx` (árbol `proveedores/` greenfield)
- **Smoke prod**: 2026-06-20 — migración `20260720000001` + hotfix `20260720000002` LIVE; 7/7 smoke cases OK
- **C2 bank-payment-routing** (2026-07-02, PR #249): `rpc_register_payment_made` rutea pagos bancarios a `bank_movements` vía `_register_bank_movement`; migración `20260804000007_bank_payment_routing.sql`. Ver `bank-movement` spec.
