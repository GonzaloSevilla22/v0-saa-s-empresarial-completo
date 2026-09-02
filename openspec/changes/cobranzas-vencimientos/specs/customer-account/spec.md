## MODIFIED Requirements

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

## ADDED Requirements

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
