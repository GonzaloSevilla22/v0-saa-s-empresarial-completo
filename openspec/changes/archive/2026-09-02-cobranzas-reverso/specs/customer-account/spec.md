## MODIFIED Requirements

### Requirement: Ledger append-only de movimientos con balance_after
El sistema SHALL proveer un ledger `customer_account_movements` (`id`, `customer_account_id` FK→`customer_accounts`, `account_id` desnormalizado para RLS, `amount numeric(15,2)`, `balance_after numeric(15,2)`, `movement_type` CHECK `sale|payment_received|payment_received_reversal|credit_note|adjustment`, `reference_id uuid` nullable, `created_by`, `created_at`). El ledger SHALL ser **append-only**: la RLS SHALL tener únicamente política SELECT (sin UPDATE ni DELETE). Cada movimiento SHALL persistir su `balance_after` (saldo de la cuenta tras aplicar el movimiento). El `balance_after` SHALL computarse a partir del saldo materializado de la cabecera bajo `SELECT ... FOR UPDATE`, **nunca** sumando el ledger en el hot path.

El tipo `payment_received_reversal` SHALL designar la anulación de un cobro y SHALL postearse con importe **positivo** (repone la deuda). SHALL ser un tipo propio y SHALL NOT reutilizarse `credit_note` para expresarlo: `credit_note` designa la reversión de un **cargo** y se postea negativo, de modo que un `credit_note` positivo invertiría el significado del tipo para todo lector que dependa de su signo. Tampoco SHALL reutilizarse `adjustment`, reservado a la corrección manual.

La ampliación del CHECK SHALL ser aditiva e idempotente: ninguna fila existente SHALL ser invalidada ni reescrita.

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

## ADDED Requirements

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
