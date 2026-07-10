## ADDED Requirements

### Requirement: Los pagos por método bancario registran un bank_movement automático
El sistema SHALL, dentro de la transacción de la RPC de pago correspondiente, registrar un `bank_movement` vía el helper `_register_bank_movement` cuando el método de pago sea bancario (transfer/card/check). Un cobro (`rpc_register_payment_received`) por método bancario SHALL generar un `bank_movement` con `amount` positivo (ingreso), `movement_type = 'transfer_in'` (o `'card_settlement'` para tarjeta), `source_doc_type = 'payment_received'` y `source_doc_ref` = id del cobro. Un pago (`rpc_register_payment_made`) por método bancario SHALL generar un `bank_movement` con `amount` negativo (egreso), `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'` y `source_doc_ref` = id del pago. El movimiento SHALL escribirse en la cuenta bancaria indicada por la RPC (`p_bank_account_id`), sobre la que aplican las validaciones de C1 (existe, pertenece a la organización, `is_active`). Estos son los **primeros escritores automáticos (no manuales)** del ledger `bank_movements`, y SHALL usar el mismo helper `_register_bank_movement` que C1 dejó como contrato C1→C2 (análogo a cómo la venta usa `c28_register_cash_movement`).

#### Scenario: Un cobro por transferencia acredita el ledger bancario
- **WHEN** se ejecuta `rpc_register_payment_received` con `payment_method = 'transfer'`, monto 400 y una cuenta bancaria activa
- **THEN** existe un `bank_movement` con `amount = +400`, `movement_type = 'transfer_in'`, `source_doc_type = 'payment_received'` y `balance_after` calculado por el helper, en el mismo commit que el cobro

#### Scenario: Un pago por transferencia debita el ledger bancario
- **WHEN** se ejecuta `rpc_register_payment_made` con `payment_method = 'transfer'`, monto 400 y una cuenta bancaria activa
- **THEN** existe un `bank_movement` con `amount = −400`, `movement_type = 'transfer_out'`, `source_doc_type = 'payment_made'`, en el mismo commit que el pago

#### Scenario: Un pago en efectivo no genera bank_movement
- **WHEN** se ejecuta una RPC de pago con `payment_method = 'cash'`
- **THEN** no se inserta ninguna fila en `bank_movements` (el efectivo va por el ledger de caja)

#### Scenario: El movimiento bancario del pago es atómico con el pago
- **WHEN** una RPC de pago por método bancario falla después de registrar el `bank_movement` (p.ej. por overpayment `P0409`)
- **THEN** ni el pago ni el `bank_movement` quedan persistidos (todo revierte en la misma transacción)

## MODIFIED Requirements

### Requirement: C1 no postea al journal contable
El sistema, a partir de este change (C2 `bank-payment-routing`), SHALL postear al journal de partida doble la contrapartida bancaria de los eventos de pago/venta cuyo método sea bancario, usando la cuenta contable `1110 Banco` (antes reservada y vacía) — reemplazando el invariante original de C1 según el cual `1110` permanecía reservada y vacía. El posteo a `1110` SHALL realizarse **asincrónicamente** vía el Consumer 3 del outbox (`_journal_post_from_event`), leyendo el `payment_method` del payload del evento, y NUNCA de forma intra-tx desde la RPC de pago. Se mantiene la separación de dos ledgers: `bank_movements` es el ledger OPERACIONAL (fuente de verdad del saldo bancario y base de la conciliación C3) escrito intra-tx por la RPC; `1110 Banco` es el espejo CONTABLE escrito async por el consumer. La conciliación futura (C3) SHALL seguir operando sobre `bank_movements`, NUNCA sobre el journal.

#### Scenario: Un pago por transferencia postea a 1110 Banco vía el consumer async
- **WHEN** se procesa (Consumer 3 del outbox) un evento `PaymentReceived`/`PaymentMade`/`SaleConfirmed` con `payment_method` bancario
- **THEN** el asiento resultante usa `1110 Banco` en la pata bancaria, y ese posteo lo hace `_journal_post_from_event` (no la RPC de pago)

#### Scenario: El movimiento operacional y el posteo contable quedan sincronizados por el outbox
- **WHEN** una RPC de pago por método bancario inserta el `bank_movement` (intra-tx) y emite el evento con `payment_method` en el payload
- **THEN** el `bank_movement` existe en el commit del pago y el asiento en `1110` aparece luego de forma idempotente al procesar el evento — sin que la conciliación (C3) dependa del journal
