## MODIFIED Requirements

### Requirement: La operación con cargo en cuenta corriente o movimiento de caja posteado es inmutable

El sistema SHALL rechazar la edición de una operación de venta o de compra que ya haya posteado un cargo en cuenta corriente (`customer_account_movements` / `supplier_account_movements`), un movimiento de caja (`cash_movements`) o un movimiento bancario (`bank_movements`) referenciándola, y SHALL hacerlo antes de iniciar el ciclo REVERSE→DELETE→INSERT, con un código de error mapeado a HTTP 409. El bloqueo SHALL alcanzar a la operación completa y no sólo al importe o a la forma de pago: la fecha, la sucursal y las líneas también determinan la atribución del movimiento espejo, de modo que permitir su edición dejaría el movimiento posteado apuntando a un hecho distinto del que registró. La corrección de una operación en ese estado SHALL canalizarse por el instrumento contable correspondiente (nota de crédito, ajuste de cuenta corriente o movimiento bancario manual de ajuste) y no por la edición, porque el ledger de cuentas corrientes es append-only por diseño, porque `difference` en el arqueo de caja es una señal antifraude (RN-95) que no puede recalcularse retroactivamente sin destruir su valor probatorio, y porque el ledger bancario es append-only con `balance_after` acumulativo y su movimiento puede estar ya conciliado dentro de una sesión cerrada.

**El asiento contable del libro diario NO es una causa de bloqueo (override del PO, 2026-08-20, `asiento-venta-formulario`)**: a diferencia de los otros tres ledgers, el libro diario de partida doble SHALL permanecer editable indefinidamente — una operación con evento `SaleOperationCreated` emitido, o con su asiento ya posteado, SHALL seguir aceptando ediciones. La corrección del asiento ante una edición se resuelve ajustándolo, no bloqueando la operación: ver la capability `journal-entry`, requirement "SaleOperationAdjusted posts a contra-entry and a new entry", para el mecanismo (reemplazo del evento pendiente in-place, o contra-entry más entry nuevo si el asiento ya procesó). Este requirement documenta la decisión explícitamente porque el design original de este mismo change había recomendado lo contrario (extender este guard al asiento contable) antes del override del PO.

#### Scenario: Editar una venta con cargo de cuenta corriente es rechazado

- **GIVEN** una venta registrada con forma de pago de `kind = 'credit'` que posteó su cargo en `customer_account_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y ni las líneas, ni el ledger de stock, ni el cargo se modifican

#### Scenario: Editar una venta con movimiento de caja es rechazado

- **GIVEN** una venta registrada desde el formulario con el opt-in de caja marcado, que generó un `cash_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y el `expected_balance` de la sesión no cambia

#### Scenario: Editar una venta con movimiento bancario es rechazado

- **GIVEN** una venta registrada con una forma de pago de `kind` bancario y destino resuelto, que generó un `bank_movements`
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423`, la respuesta HTTP es 409, y el `bank_movement` conserva su `amount`, su `balance_after` y su estado de conciliación

#### Scenario: Editar una compra con movimiento bancario es rechazado

- **GIVEN** una compra imputada a una forma de pago de `kind` bancario con destino resuelto, que generó un `bank_movements` de egreso
- **WHEN** se intenta editar esa operación
- **THEN** la operación falla con `P0423` y el ledger bancario no cambia

#### Scenario: Una venta del formulario con asiento contable emitido sigue siendo editable

- **GIVEN** una venta registrada desde el formulario cuya transacción emitió el evento `SaleOperationCreated`, ya sea pendiente de proceso o ya posteado como asiento
- **WHEN** se intenta editar esa operación, sin cargo en cuenta corriente, sin movimiento de caja y sin movimiento bancario
- **THEN** la edición procede — no hay `P0423` por causa del asiento contable — y el rastro contable se ajusta según el mecanismo de la capability `journal-entry`

#### Scenario: Una operación sin ningún rastro contable sigue siendo editable

- **GIVEN** una venta del formulario registrada antes de que existiera el productor del evento contable, sin cargo en cuenta corriente, sin movimiento de caja, sin movimiento bancario y sin evento emitido
- **WHEN** se edita esa operación cambiando importe y forma de pago
- **THEN** la edición procede normalmente con el acarreo de contexto ya establecido, y no se emite ningún evento contable para esa edición

#### Scenario: El mensaje de error distingue la causa

- **WHEN** se intenta editar una operación bloqueada por un movimiento bancario
- **THEN** el mensaje nombra el movimiento bancario como causa y sugiere el ajuste manual en el ledger bancario como vía de corrección

#### Scenario: La superficie anticipa el bloqueo

- **WHEN** el usuario abre el listado de operaciones y una de ellas tiene cargo, movimiento de caja o movimiento bancario posteado
- **THEN** la acción de editar aparece deshabilitada con la razón visible, en vez de fallar recién al confirmar; una operación con asiento contable pero sin cargo/movimiento de pago sigue mostrando "Editar" habilitado, porque el asiento no es causa de bloqueo (override del PO)
