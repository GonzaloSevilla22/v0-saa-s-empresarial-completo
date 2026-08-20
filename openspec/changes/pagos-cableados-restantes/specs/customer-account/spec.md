## ADDED Requirements

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
