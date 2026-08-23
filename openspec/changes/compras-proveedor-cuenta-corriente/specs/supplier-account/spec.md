## ADDED Requirements

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

## MODIFIED Requirements

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
