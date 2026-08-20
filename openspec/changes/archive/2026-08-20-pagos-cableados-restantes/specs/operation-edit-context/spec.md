## ADDED Requirements

### Requirement: La operación con cargo en cuenta corriente o movimiento de caja posteado es inmutable

El sistema SHALL rechazar la edición de una operación de venta o de compra que ya haya posteado un cargo en cuenta corriente (`customer_account_movements` / `supplier_account_movements`) o un movimiento de caja (`cash_movements`) referenciándola, y SHALL hacerlo antes de iniciar el ciclo REVERSE→DELETE→INSERT, con un código de error mapeado a HTTP 409. El bloqueo SHALL alcanzar a la operación completa y no sólo al importe o a la forma de pago: la fecha, la sucursal y las líneas también determinan la atribución del movimiento espejo, de modo que permitir su edición dejaría el movimiento posteado apuntando a un hecho distinto del que registró. La corrección de una operación en ese estado SHALL canalizarse por el instrumento contable correspondiente (nota de crédito o ajuste de cuenta corriente) y no por la edición, porque el ledger de cuentas corrientes es append-only por diseño y porque `difference` en el arqueo de caja es una señal antifraude (RN-95) que no puede recalcularse retroactivamente sin destruir su valor probatorio. El mensaje de error SHALL nombrar la causa concreta —cargo de cuenta corriente o movimiento de caja— para que el usuario sepa qué instrumento usar.

#### Scenario: Editar una venta con cargo de cuenta corriente es rechazado

- **GIVEN** una venta registrada con forma de pago de `kind = 'credit'` que posteó su cargo en `customer_account_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y ni las líneas, ni el ledger de stock, ni el cargo se modifican

#### Scenario: Editar una venta con movimiento de caja es rechazado

- **GIVEN** una venta registrada desde el formulario con el opt-in de caja marcado, que generó un `cash_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y el `expected_balance` de la sesión no cambia

#### Scenario: Una venta sin cargo ni movimiento sigue siendo editable

- **GIVEN** una venta imputada a una forma de pago de `kind = 'transfer'`, sin cargo en cuenta corriente ni movimiento de caja
- **WHEN** se edita esa operación cambiando importe y forma de pago
- **THEN** la edición procede normalmente con el acarreo de contexto ya establecido

#### Scenario: El mensaje de error distingue la causa

- **WHEN** se intenta editar una operación bloqueada por un cargo de cuenta corriente
- **THEN** el mensaje nombra el cargo de cuenta corriente como causa y sugiere la nota de crédito como vía de corrección

#### Scenario: La superficie anticipa el bloqueo

- **WHEN** el usuario abre el listado de operaciones y una de ellas tiene cargo o movimiento posteado
- **THEN** la acción de editar aparece deshabilitada con la razón visible, en vez de fallar recién al confirmar
