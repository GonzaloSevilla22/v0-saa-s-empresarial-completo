# branches

## ADDED Requirements

### Requirement: Lifecycle operacional de sucursal (open/close)
El sistema SHALL mantener en cada sucursal un estado operacional `status` (`'active'` | `'closed'`) independiente del soft-delete (`is_active`), con timestamps `opened_at`/`closed_at`, modificable únicamente por `owner`/`admin` vía `rpc_open_branch(p_branch_id)` y `rpc_close_branch(p_branch_id)`.

#### Scenario: Owner cierra una sucursal sin stock
- **GIVEN** una sucursal con `status = 'active'` y `Σ branch_stock = 0`
- **WHEN** el owner llama a `rpc_close_branch`
- **THEN** `status` pasa a `'closed'`, `closed_at = now()`, y la sucursal sigue visible en historial y reportes (`is_active` no cambia)

#### Scenario: Owner reabre una sucursal cerrada
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** el owner llama a `rpc_open_branch`
- **THEN** `status` pasa a `'active'` y `opened_at = now()`

#### Scenario: Member no puede operar el lifecycle
- **GIVEN** un usuario con rol `member` en la cuenta
- **WHEN** llama a `rpc_open_branch` o `rpc_close_branch`
- **THEN** la RPC retorna error `P0401` (solo owner/admin)

### Requirement: Cierre de sucursal bloqueado con stock o si es la última operativa
El sistema SHALL rechazar `rpc_close_branch` si la sucursal tiene stock (`Σ branch_stock > 0`, error `P0409 branch_has_stock`) o si es la última sucursal con `status = 'active'` de la cuenta (error `P0409 last_active_branch`).

#### Scenario: Cierre con stock es rechazado
- **GIVEN** una sucursal con 5 unidades de algún producto en `branch_stock`
- **WHEN** el owner llama a `rpc_close_branch`
- **THEN** la RPC retorna `P0409 branch_has_stock` y el estado no cambia (transferir el stock primero)

#### Scenario: No se puede cerrar la única sucursal operativa
- **GIVEN** una cuenta cuya única sucursal con `status = 'active'` es la default
- **WHEN** el owner intenta cerrarla
- **THEN** la RPC retorna `P0409 last_active_branch`

### Requirement: Operaciones solo contra sucursales operativas
El sistema SHALL rechazar ventas, compras, ajustes y transferencias que referencien explícitamente una sucursal con `status = 'closed'`, con error `P0422 branch_closed`.

#### Scenario: Venta en sucursal cerrada falla
- **GIVEN** una sucursal con `status = 'closed'`
- **WHEN** se registra una venta con `p_branch_id` de esa sucursal
- **THEN** la RPC retorna `P0422 branch_closed` y no inserta ninguna fila

#### Scenario: Transferencia hacia o desde sucursal cerrada falla
- **GIVEN** una transferencia cuyo origen o destino tiene `status = 'closed'`
- **WHEN** se llama a `rpc_transfer_stock`
- **THEN** la RPC retorna `P0422 branch_closed` y no modifica ningún ledger

#### Scenario: UI muestra estado y acciones de lifecycle
- **GIVEN** el owner navega a `/sucursales/:id`
- **WHEN** la página carga
- **THEN** ve el badge de estado (`Activa`/`Cerrada`), el botón Abrir/Cerrar con confirmación, y el listado de transferencias de la sucursal
