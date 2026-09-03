## MODIFIED Requirements

### Requirement: Ledger append-only de movimientos del proveedor con balance_after
El sistema SHALL proveer un ledger `supplier_account_movements` (`id`, `supplier_account_id` FK→`supplier_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `purchase|payment_made|payment_made_reversal|debit_note|adjustment`, `reference_id uuid` nullable, **`due_date date` nullable**, `created_by`, `created_at`). El ledger SHALL ser **append-only** (RLS solo SELECT, sin UPDATE/DELETE). Cada movimiento SHALL persistir su `balance_after`, computado a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

El tipo `payment_made_reversal` SHALL designar la anulación de un pago a proveedor y SHALL postearse con importe **positivo** (repone la deuda con el proveedor). SHALL ser un tipo propio y SHALL NOT reutilizarse `debit_note`, que designa la reversión de un **cargo** y se postea negativo, ni `adjustment`, reservado a la corrección manual.

`due_date` SHALL designar el **vencimiento del cargo** —la fecha en que corresponde pagarle al proveedor— y SHALL poblarse únicamente en los movimientos que constituyen un cargo; en los demás SHALL quedar nulo. SHALL escribirse en el mismo `INSERT` que crea el movimiento y NO SHALL actualizarse después. Su ausencia SHALL significar "cargo sin vencimiento", y los movimientos anteriores a la incorporación de la columna SHALL conservarla nula, sin backfill. Es el espejo exacto del lado cliente.

La ampliación del CHECK SHALL ser aditiva e idempotente: ninguna fila existente SHALL ser invalidada ni reescrita. La incorporación de `due_date` SHALL ser igualmente aditiva y nullable.

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

#### Scenario: El cargo de compra lleva su vencimiento y el pago no
- **WHEN** se postea un cargo por una compra a crédito con vencimiento y luego un pago sobre la misma cuenta
- **THEN** la fila del cargo lleva su `due_date` y la del pago lo tiene nulo

#### Scenario: Los movimientos históricos de proveedor quedan sin vencimiento
- **GIVEN** los movimientos existentes al momento de incorporar la columna
- **WHEN** se aplica la migración, incluso dos veces
- **THEN** todas esas filas quedan con vencimiento nulo y ninguna es reescrita

### Requirement: Helper intra-transacción c30_register_supplier_account_movement
El sistema SHALL proveer `public.c30_register_supplier_account_movement(p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid DEFAULT NULL, p_due_date date DEFAULT NULL) RETURNS uuid` con `SET search_path = public`, **REVOKE de PUBLIC**, que **NO abre transacción propia**, espejo exacto de `c30_register_customer_account_movement`: lock de cabecera con `FOR UPDATE`, `balance_after = balance + p_amount`, INSERT append-only con el vencimiento recibido, UPDATE de la cabecera, RETURN id. La acumulación SHALL usar UPDATE-then-INSERT, nunca `ON CONFLICT DO UPDATE` con delta.

El parámetro de vencimiento SHALL ser **el último y opcional**, y la redefinición SHALL realizarse por baja y alta explícitas de la función —nunca por reemplazo en el lugar con un argumento nuevo con valor por omisión, que dejaría viva la definición anterior como sobrecarga—, reafirmando los permisos en el mismo archivo de migración.

#### Scenario: el helper serializa con FOR UPDATE
- **WHEN** dos movimientos concurrentes sobre la misma `SupplierAccount` se postean
- **THEN** el lock de cabecera los serializa y ambos quedan reflejados en el saldo final

#### Scenario: el helper no es callable desde authenticated
- **WHEN** el rol `authenticated` intenta invocar el helper directamente
- **THEN** la llamada es denegada (REVOKE de PUBLIC)

#### Scenario: El vencimiento llega a la fila del proveedor
- **WHEN** se invoca el helper con un vencimiento
- **THEN** la fila insertada en el ledger de proveedor lo lleva

#### Scenario: No queda una definición anterior viva del helper de proveedor
- **WHEN** se inspecciona el catálogo de funciones tras la migración
- **THEN** existe exactamente una definición del helper, con el argumento de vencimiento

## ADDED Requirements

### Requirement: El historial de cuenta corriente del proveedor expone el vencimiento y el saldo abierto de cada cargo

El sistema SHALL exponer, para cada movimiento del historial de cuenta corriente de un proveedor, su **vencimiento**, si está **vencido**, cuántos **días de atraso** acumula y qué **importe permanece abierto** tras la imputación de pagos, con las mismas reglas de derivación que rigen para el lado cliente.

Esos derivados SHALL calcularse en el servidor, dentro de la consulta que recupera los movimientos, SHALL viajar por **todas** las consultas que alimentan el historial —no sólo por la paginada—, y NO SHALL reimplementarse en la interfaz.

Un movimiento que no es un cargo SHALL exponer sus derivados de vencimiento como ausentes, no como cero.

#### Scenario: Un cargo de compra vencido en el historial

- **GIVEN** un cargo de 8000 con vencimiento hace 10 días, cancelado parcialmente por un pago de 3000
- **WHEN** el usuario abre el historial de cuenta corriente del proveedor
- **THEN** esa fila muestra su vencimiento, que está vencida, 10 días de atraso y 5000 de importe abierto

#### Scenario: Un pago no tiene vencimiento

- **WHEN** el historial muestra un movimiento de pago a proveedor
- **THEN** sus derivados de vencimiento se presentan como ausentes y no como cero

#### Scenario: Todas las consultas del historial de proveedor traen los derivados

- **WHEN** se recuperan los movimientos de una cuenta corriente de proveedor por cualquiera de las consultas que alimentan el historial
- **THEN** todas devuelven el vencimiento, el estado de vencimiento, los días de atraso y el importe abierto
