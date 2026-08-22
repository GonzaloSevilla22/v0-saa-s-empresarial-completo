## MODIFIED Requirements

### Requirement: RPC de carga manual de movimiento bancario
El sistema SHALL exponer `rpc_register_bank_movement` (SECURITY DEFINER, GRANT a `authenticated`) para registrar movimientos bancarios **manualmente**. Esta RPC SHALL aceptar el subconjunto manual de `movement_type`: `{'transfer_in', 'transfer_out', 'manual_adjustment', 'fee', 'tax_debit', 'interest'}` — los tres últimos habilitados por C3 `bank-reconciliation` para anotar cargos del extracto sin contraparte en el sistema — rechazando el tipo reservado a escritores automáticos (`card_settlement`) con `P0410`. La RPC SHALL estar guardada por `is_account_writer` (`P0401` si no), SHALL rechazar movimientos sobre una cuenta inexistente o inactiva (`P0412`), y SHALL ser idempotente vía `idempotency_key` (slot en `operation_idempotency`, replay devuelve el resultado original sin re-insertar). Adicionalmente, cuando el `movement_type` es `manual_adjustment`, la RPC SHALL exigir una descripción no vacía y rechazar la llamada con `P0413` si no se provee, porque un ajuste sin motivo es indistinguible de un error de carga.

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

#### Scenario: Ajuste manual sin motivo es rechazado
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `movement_type = 'manual_adjustment'` y `p_description` nula o en blanco
- **THEN** la RPC retorna `P0413` y no inserta ninguna fila, y el slot de idempotencia no queda consumido para esa clave

#### Scenario: Ajuste manual con motivo se registra
- **WHEN** un usuario con permiso llama a `rpc_register_bank_movement` con `movement_type = 'manual_adjustment'`, `amount = -1200` y una descripción no vacía
- **THEN** el movimiento se registra con su `balance_after` y la descripción persistida

## ADDED Requirements

### Requirement: El motivo obligatorio del ajuste bancario está garantizado por la tabla
El sistema SHALL replicar la exigencia de motivo del ajuste bancario mediante un CHECK sobre `bank_movements` que obligue a `description` no vacía cuando `movement_type = 'manual_adjustment'`, para que ningún escritor —presente o futuro, RPC o helper— pueda insertar un ajuste sin motivo. El CHECK SHALL agregarse sin reescribir las filas históricas, que no incluyen ajustes manuales.

#### Scenario: Inserción directa de un ajuste sin motivo
- **WHEN** cualquier camino de escritura intenta insertar un `bank_movement` con `movement_type = 'manual_adjustment'` y `description` nula o en blanco
- **THEN** la inserción falla por violación del CHECK

#### Scenario: Los demás tipos no quedan alcanzados
- **WHEN** se inserta un `bank_movement` de tipo `transfer_in` sin descripción
- **THEN** la inserción se completa normalmente

### Requirement: Los movimientos bancarios son consultables por cuenta desde el módulo Banco
El sistema SHALL exponer el ledger bancario como un historial legible por cuenta bancaria en el módulo Banco, ordenado por fecha valor descendente, con el tipo de movimiento etiquetado, el importe con signo, el saldo resultante y el estado de conciliación de cada fila. El historial SHALL ser de sólo lectura y NO SHALL ofrecer edición ni borrado, en coherencia con el carácter append-only del ledger.

#### Scenario: Consultar los movimientos de una cuenta
- **GIVEN** una cuenta bancaria con movimientos automáticos de pagos y movimientos manuales
- **WHEN** el usuario abre el historial de esa cuenta
- **THEN** ve unos y otros en la misma lista, cada uno con su tipo etiquetado y su estado de conciliación

#### Scenario: El historial no altera el ledger
- **WHEN** el usuario opera el historial (filtra, pagina, exporta)
- **THEN** ninguna fila de `bank_movements` es modificada
