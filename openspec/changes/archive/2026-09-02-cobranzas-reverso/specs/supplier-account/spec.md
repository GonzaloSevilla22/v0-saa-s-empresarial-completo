## MODIFIED Requirements

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

## ADDED Requirements

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
