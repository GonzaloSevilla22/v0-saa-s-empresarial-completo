# bank-movement Specification (delta)

## MODIFIED Requirements

### Requirement: Taxonomía de tipos de movimiento bancario
El sistema SHALL fijar mediante CHECK el conjunto completo de `movement_type` desde ya: `{'transfer_in', 'transfer_out', 'card_settlement', 'fee', 'tax_debit', 'interest', 'manual_adjustment'}`. El `value_date` SHALL representar la fecha valor bancaria, distinta de `created_at`. A partir de este change (C3 `bank-reconciliation`), los tipos `fee`, `tax_debit` (impuesto al cheque, Ley 25.413) e `interest` SHALL ser emitibles por la carga manual (habilitan el "solo anotar" de la conciliación V1). El tipo `card_settlement` SHALL permanecer RESERVADO a los escritores automáticos (RPCs de pago de C2) y NO ser emitible manualmente.

#### Scenario: El CHECK acepta el enum completo
- **WHEN** se inspecciona el `CHECK` de `bank_movements.movement_type`
- **THEN** incluye los 7 tipos `transfer_in`, `transfer_out`, `card_settlement`, `fee`, `tax_debit`, `interest`, `manual_adjustment`

#### Scenario: Un movement_type fuera del enum es rechazado por el CHECK
- **WHEN** se intenta insertar un `bank_movement` con `movement_type = 'foo'`
- **THEN** la inserción falla por violación del CHECK del enum

### Requirement: RPC de carga manual de movimiento bancario
El sistema SHALL exponer `rpc_register_bank_movement` (SECURITY DEFINER, GRANT a `authenticated`) para registrar movimientos bancarios **manualmente**. Esta RPC SHALL aceptar el subconjunto manual de `movement_type`: `{'transfer_in', 'transfer_out', 'manual_adjustment', 'fee', 'tax_debit', 'interest'}` — los tres últimos habilitados por C3 `bank-reconciliation` para anotar cargos del extracto sin contraparte en el sistema — rechazando el tipo reservado a escritores automáticos (`card_settlement`) con `P0410`. La RPC SHALL estar guardada por `is_account_writer` (`P0401` si no), SHALL rechazar movimientos sobre una cuenta inexistente o inactiva (`P0412`), y SHALL ser idempotente vía `idempotency_key` (slot en `operation_idempotency`, replay devuelve el resultado original sin re-insertar).

#### Scenario: Registrar una transferencia manual
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `amount = +5000`, `movement_type = 'transfer_in'` y una `idempotency_key` nueva sobre una cuenta activa
- **THEN** se registra el movimiento (vía el helper) con su `balance_after` y la RPC devuelve `replayed = false`

#### Scenario: Anotar una comisión bancaria manualmente
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `amount = -350`, `movement_type = 'fee'` y una `idempotency_key` nueva sobre una cuenta activa
- **THEN** se registra el movimiento con `balance_after` calculado (el tipo dejó de estar reservado)

#### Scenario: La RPC manual rechaza card_settlement
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `movement_type = 'card_settlement'`
- **THEN** la RPC retorna `P0410` y no inserta ninguna fila (el tipo queda reservado a los escritores automáticos de C2)

#### Scenario: Un usuario sin permiso de escritura no puede registrar
- **WHEN** un usuario de solo lectura llama a `rpc_register_bank_movement`
- **THEN** la RPC retorna `P0401` y no inserta ninguna fila

#### Scenario: Movimiento sobre cuenta inactiva es rechazado
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` sobre una cuenta con `is_active = false`
- **THEN** la RPC retorna `P0412` y no inserta ninguna fila

#### Scenario: Doble submit con la misma idempotency_key no duplica
- **WHEN** se llama dos veces a `rpc_register_bank_movement` con la misma `idempotency_key` y los mismos datos
- **THEN** la segunda llamada devuelve el resultado original con `replayed = true` y existe una sola fila en `bank_movements`

## ADDED Requirements

### Requirement: Estado de conciliación del movimiento bancario
El sistema SHALL exponer en `bank_movements` el estado de conciliación mediante columnas aditivas `reconciliation_status TEXT NOT NULL DEFAULT 'unreconciled' CHECK IN ('unreconciled','matched')` y `reconciled_at TIMESTAMPTZ NULL`. Estas columnas SHALL ser mantenidas EXCLUSIVAMENTE por las RPCs de conciliación (match/unmatch de C3) en la misma transacción del match — ningún otro escritor (helper `_register_bank_movement`, RPCs de pago, carga manual) las setea, y sigue sin existir UPDATE directo para `authenticated`. Este UPDATE controlado de columnas de estado NO viola el carácter append-only del ledger: los campos económicos (`amount`, `balance_after`, `movement_type`, `value_date`) permanecen inmutables.

#### Scenario: Un movimiento nuevo nace sin conciliar
- **WHEN** se registra un `bank_movement` (manual o automático)
- **THEN** la fila tiene `reconciliation_status = 'unreconciled'` y `reconciled_at IS NULL`

#### Scenario: Solo las RPCs de conciliación cambian el estado
- **WHEN** la RPC de match de una sesión abierta concilia el movimiento
- **THEN** `reconciliation_status = 'matched'` con `reconciled_at` seteado; y **WHEN** el rol `authenticated` intenta un UPDATE directo de esas columnas, **THEN** la operación es rechazada (sin policy de UPDATE)

#### Scenario: Los campos económicos siguen inmutables
- **WHEN** un movimiento pasa a `matched`
- **THEN** `amount`, `balance_after`, `movement_type` y `value_date` no cambian
