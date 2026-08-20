## ADDED Requirements

### Requirement: Las operaciones de venta y compra por método bancario registran un bank_movement automático

El sistema SHALL registrar, dentro de la misma transacción que la operación, un `bank_movement` vía el helper `_register_bank_movement` cuando el `kind` derivado de la forma de pago imputada sea bancario (`transfer`, `card`, `check`, `wallet`) **y** se haya resuelto una cuenta bancaria destino. Esto SHALL aplicar a los tres caminos de alta de operación: el mostrador (`rpc_quick_sale` / `rpc_confirm_sales_order` → `_c29_confirm_order_core`), el formulario de venta (`rpc_create_sale_operation` / `_v2`) y el formulario de compra (`rpc_create_purchase_operation`), convirtiéndolos en los segundos escritores automáticos del ledger después de las RPCs de pago de C2. Una venta SHALL generar un movimiento de ingreso con `amount = +total`, `source_doc_type = 'sale'`; una compra SHALL generar uno de egreso con `amount = −total`, `source_doc_type = 'purchase'`. El `movement_type` SHALL derivarse del `kind` según el mapa `transfer|check|wallet → transfer_in` (venta) / `transfer_out` (compra) y `card → card_settlement`, extendiendo a `wallet` el criterio bancario que la capability `journal-entry` ya le aplica al rutearlo a `1110 Banco`. Los `kind` `cash`, `credit` y `other` NO SHALL generar movimiento bancario por ningún camino, de modo que una venta a cuenta corriente registre su movimiento bancario recién cuando se cobre (vía `rpc_register_payment_received`) y nunca dos veces. El `kind` SHALL derivarse en el servidor desde `payment_method_id`, nunca aceptarse como dato del cliente. La escritura SHALL concentrarse en un único helper compartido por los tres caminos, y NO SHALL emitir eventos de outbox ni escribir en el journal: el `bank_movement` es el ledger OPERATIVO y su espejo contable en `1110 Banco` lo sigue posteando de forma asíncrona `_journal_post_from_event`.

#### Scenario: Una venta del POS por transferencia acredita el ledger bancario

- **GIVEN** una forma de pago de `kind = 'transfer'` con una cuenta bancaria activa configurada como destino
- **WHEN** se cobra desde el POS una venta de 10.000 con esa forma de pago
- **THEN** existe, en el mismo commit que el descuento de stock, un `bank_movement` con `amount = +10000`, `movement_type = 'transfer_in'`, `source_doc_type = 'sale'` y `balance_after` calculado por el helper

#### Scenario: Una compra por transferencia debita el ledger bancario

- **GIVEN** una forma de pago de `kind = 'transfer'` con una cuenta bancaria activa configurada como destino
- **WHEN** se registra una compra de 4.000 imputada a esa forma de pago
- **THEN** existe un `bank_movement` con `amount = −4000`, `movement_type = 'transfer_out'` y `source_doc_type = 'purchase'`, en el mismo commit que la compra

#### Scenario: Una venta con tarjeta se asienta bruta

- **WHEN** se cobra una venta de 10.000 con una forma de pago de `kind = 'card'` con cuenta destino resuelta
- **THEN** el `bank_movement` registra `amount = +10000` (el bruto) con `movement_type = 'card_settlement'`, y la comisión no se descuenta automáticamente

#### Scenario: Una venta en efectivo o a cuenta corriente no toca el banco

- **WHEN** se cobra una venta con una forma de pago de `kind = 'cash'` o de `kind = 'credit'`
- **THEN** no se inserta ninguna fila en `bank_movements`

#### Scenario: La venta a cuenta corriente registra el movimiento recién al cobrarse

- **GIVEN** una venta registrada con `kind = 'credit'` que posteó su cargo en la cuenta corriente del cliente
- **WHEN** más tarde se registra el cobro con `rpc_register_payment_received` por método bancario
- **THEN** existe exactamente un `bank_movement` para ese ciclo, el del cobro, sin duplicación con la venta

#### Scenario: El movimiento es atómico con la operación

- **WHEN** el alta de la venta falla después de resolver la cuenta bancaria (por ejemplo por stock insuficiente)
- **THEN** no queda ninguna fila en `bank_movements` ni en `sales` (todo revierte en la misma transacción)

#### Scenario: El movimiento de la operación no genera asiento por sí mismo

- **WHEN** una venta por método bancario registra su `bank_movement`
- **THEN** la RPC no inserta filas en `journal_entries`/`journal_lines` ni emite eventos nuevos, y la contrapartida en `1110 Banco` sigue llegando de forma asíncrona por el consumer del outbox desde el evento `SaleConfirmed` ya existente

### Requirement: Resolución de la cuenta bancaria destino de una operación

El sistema SHALL resolver la cuenta bancaria destino de una operación en el siguiente orden: (1) el parámetro explícito de la operación (`p_bank_account_id`), si se informó; (2) el destino por defecto configurado en la forma de pago imputada (`payment_methods.bank_account_id`); (3) ninguna. Cuando no se resuelve ninguna cuenta, la operación SHALL completarse normalmente **sin** registrar movimiento bancario — la ausencia de configuración es un camino válido y silencioso, porque el ledger bancario es opcional y la mayoría de las organizaciones no lleva sus cuentas bancarias en el sistema. La cuenta resuelta SHALL validarse siempre: existir, pertenecer a la organización de la operación, estar activa (`is_active`) y no estar borrada (`deleted_at IS NULL`); si falla cualquiera de esas condiciones la operación SHALL rechazarse con `P0412` y no registrarse. Informar una cuenta bancaria explícita junto a un `kind` no bancario SHALL rechazarse con `P0400`, en vez de ignorarse en silencio.

#### Scenario: El default por método se aplica sin intervención

- **GIVEN** la forma de pago "Transferencia bancaria" con la cuenta "Galicia CC" configurada como destino
- **WHEN** se cobra una venta con esa forma de pago sin informar cuenta en la operación
- **THEN** el `bank_movement` se registra contra "Galicia CC"

#### Scenario: El override de la operación gana sobre el default

- **GIVEN** la misma forma de pago con default "Galicia CC"
- **WHEN** se cobra una venta con esa forma de pago informando explícitamente la cuenta "Santander CA"
- **THEN** el `bank_movement` se registra contra "Santander CA" y no contra el default

#### Scenario: Sin cuenta resuelta la venta sigue funcionando igual que antes

- **GIVEN** una forma de pago de `kind = 'transfer'` sin destino configurado y una operación que no informa cuenta
- **WHEN** se cobra la venta
- **THEN** la venta se confirma normalmente y no se inserta ninguna fila en `bank_movements`

#### Scenario: Cuenta bancaria de otra organización es rechazada

- **WHEN** una operación informa una cuenta bancaria que pertenece a otra organización
- **THEN** la RPC retorna `P0412` y no se registra ni la operación ni el movimiento

#### Scenario: Cuenta bancaria inactiva o borrada es rechazada

- **WHEN** la cuenta resuelta tiene `is_active = false` o `deleted_at` no nulo
- **THEN** la RPC retorna `P0412` y no se registra ni la operación ni el movimiento

#### Scenario: Cuenta bancaria informada sobre un kind no bancario es rechazada

- **WHEN** una operación con forma de pago de `kind = 'cash'` informa una cuenta bancaria explícita
- **THEN** la RPC retorna `P0400` y no se registra la operación

### Requirement: La fecha valor del movimiento de una operación respeta los períodos ya conciliados

El sistema SHALL usar como `value_date` del movimiento la fecha de la operación —el día local del tenant en el camino del mostrador (canon `business-day-timezone`) y la fecha informada en los formularios— y SHALL rechazar con `P0424` el registro de un movimiento cuya `value_date` caiga dentro del período (`period_from`..`period_to`) de una sesión de conciliación en estado `closed` de esa misma cuenta bancaria. El rechazo SHALL alcanzar a la operación completa, no sólo al movimiento, para no dejar una venta registrada cuyo efecto bancario se perdió en silencio, y el mensaje SHALL indicar que el ajuste corresponde registrarlo como movimiento manual. Esta regla protege la conciliación ya firmada: un movimiento aparecido después del cierre no tendría línea de extracto disponible para matchearse y quedaría huérfano en el ledger para siempre.

#### Scenario: El movimiento del mostrador toma el día local

- **WHEN** se cobra una venta desde el POS por transferencia
- **THEN** el `bank_movement` nace con `value_date` igual al día local del tenant, no a la fecha UTC del servidor

#### Scenario: Una operación retroactiva dentro de un período conciliado es rechazada

- **GIVEN** una sesión de conciliación `closed` sobre la cuenta destino que cubre el período del mes anterior
- **WHEN** se registra desde el formulario una venta por transferencia con fecha dentro de ese período
- **THEN** la operación falla con `P0424`, no se registra la venta ni el movimiento, y el mensaje indica registrar un ajuste manual

#### Scenario: Una operación retroactiva fuera de todo período conciliado procede

- **GIVEN** una sesión de conciliación `closed` que cubre el mes anterior
- **WHEN** se registra una venta por transferencia con fecha posterior al `period_to` de esa sesión
- **THEN** la operación se registra y el `bank_movement` queda `unreconciled`, disponible para la próxima sesión

### Requirement: El movimiento de una operación es conciliable sin piezas nuevas

El sistema SHALL hacer que el movimiento generado por una operación nazca con `reconciliation_status = 'unreconciled'` y `reconciled_at IS NULL`, quedando disponible para el matching de la capability `bank-reconciliation` exactamente igual que un movimiento manual o uno de las RPCs de pago. NO SHALL existir un estado intermedio de "movimiento esperado" distinto de `unreconciled`: el movimiento operativo generado por la venta **es** el esperado, y su confirmación bancaria es el match contra la línea de extracto. La conciliación de una venta con tarjeta, cuyo bruto no coincide con el neto acreditado por el adquirente, SHALL resolverse con el instrumento ya existente: un match N:1 que agrupe el movimiento de la venta con los movimientos manuales `fee`/`tax_debit` de la comisión, cuya suma iguale la línea del extracto.

#### Scenario: El movimiento de la venta nace conciliable

- **WHEN** una venta por transferencia registra su `bank_movement`
- **THEN** la fila tiene `reconciliation_status = 'unreconciled'` y `reconciled_at IS NULL`

#### Scenario: La sugerencia automática engancha el movimiento de una venta

- **GIVEN** un `bank_movement` de `+10000` generado por una venta por transferencia y una línea de extracto importada de `+10000` con `value_date` dentro de ±3 días
- **WHEN** el usuario pide sugerencias en una sesión abierta de esa cuenta
- **THEN** el par aparece como sugerencia 1:1 a confirmar, y al confirmarla el movimiento queda `matched`

#### Scenario: La venta con tarjeta se concilia neteando la comisión con un match N:1

- **GIVEN** un `bank_movement` de `+10000` con `movement_type = 'card_settlement'` y un `bank_movement` manual de `−350` con `movement_type = 'fee'`
- **WHEN** el usuario los matchea contra una línea de extracto de `+9650`
- **THEN** el match se crea (la suma del grupo iguala la línea) y ambos movimientos quedan `matched`
