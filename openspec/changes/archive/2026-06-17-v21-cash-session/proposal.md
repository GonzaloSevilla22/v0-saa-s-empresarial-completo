# Proposal — v21-cash-session (C-28)

## Why

El sistema hoy no tiene caja: registra ventas, pero no sabe cuánto efectivo entró ni cuánto debería haber en el cajón al cerrar el día. En retail argentino esto no es opcional — el arqueo de caja (declarado vs esperado) es la herramienta diaria de control antifraude que los comercios piden explícitamente (RN-95). El modelo de dominio V2 (DEC-19, §3.7) define `Cashbox` colgando de `Branch` y `CashSession` con ciclo `OPEN → CLOSED` + arqueo. Es el momento óptimo: post-C-26 `Branch` ya es Aggregate Root con lifecycle (`status active/closed`, `opened_at/closed_at`), así que la caja se cuelga de un agregado estable; y C-29 (`v21-quote-salesorder`, el hot path de venta) aún no existe, lo que permite **diseñar ahora el punto de integración** (un movimiento de caja generado en la misma transacción que la venta — DEC-20) para que C-29 lo enchufe sin re-arquitectura.

En producción ninguna cuenta tiene cajas todavía (feature nueva), así que las tablas, invariantes y RLS nacen limpios, sin backfill ni riesgo sobre datos existentes.

## What Changes

- **`Cashbox` por sucursal**: tabla `cashboxes` (`id`, `branch_id` FK `branches`, `name`, `currency DEFAULT 'ARS'`, `created_at`) — una sucursal puede tener varias cajas físicas. RLS por `account_id` resuelto vía `branch_id → branches.account_id` (NO `company_id`/`user_id` — RN-97).
- **`CashSession` con ciclo de vida**: tabla `cash_sessions` (`id`, `cashbox_id` FK, `status ('open'|'closed')`, `opening_balance`, `closing_balance`, `counted_balance`, `expected_balance`, `difference`, `opened_by`, `closed_by`, `opened_at`, `closed_at`). Comandos `open(opening_balance)` / `close(counted_balance)` que calcula `expected = opening + Σ movimientos`, registra `difference = counted - expected` (el arqueo).
- **`CashMovement` append-only**: tabla `cash_movements` (`id`, `session_id` FK, `amount NUMERIC`, `movement_type`, `reference_id UUID NULL`, `balance_after NUMERIC`, `created_by`, `created_at`). Tipos: `sale`, `purchase_payment`, `expense`, `advance`, `withdrawal`. Patrón ledger contable (DEC, RN-98): `balance_after` por fila, igual que `stock_movements`.
- **Invariante de apertura única (BREAKING para la operación)**: no se puede abrir una `CashSession` si ya hay una `open` en la misma `Cashbox` (índice UNIQUE parcial `WHERE status='open'` + guard en RPC, error `P0409 cashbox_session_open`).
- **Invariante de sesión obligatoria**: todo `CashMovement` exige una sesión `open` (RN-95); insertar movimiento sin sesión abierta → error `P0409 no_open_session`.
- **Punto de integración hot-path (DEC-20) — listo para C-29**: función SQL reutilizable `rpc_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id)` (o helper interno `c28_register_cash_movement(...)` invocable desde otra RPC dentro de la MISMA transacción). C-29 (`SalesOrder.confirm()` / `quickSale()`) llamará al helper para que una venta en efectivo inserte su `cash_movement` atómicamente con el descuento de stock. En C-28 el helper queda implementado y testeado de forma autónoma (sin dependencia de C-29).
- **Caja contra sucursal cerrada falla**: abrir sesión o registrar movimiento en una caja cuya `branch.status='closed'` retorna `P0422 branch_closed` (reusa el patrón de C-26).
- **Backend Python**: `CashboxRepository` / `CashSessionRepository` (`open_session`, `close_session`, `register_movement`, `list_movements`, `list_cashboxes`, `current_session`); router `cash` (endpoints REST); schemas Pydantic v2. Arquitectura 3 capas (routers → services con `require_role` → repositories).
- **UI `/sucursales/:id/caja`**: apertura de sesión (form de saldo inicial), listado de movimientos de la sesión activa, cierre con arqueo (input de efectivo contado → diferencia visible), historial de sesiones cerradas con su diferencia.

## Capabilities

### New Capabilities

- `cash-session`: ciclo de vida de la sesión de caja (open/close), invariante de apertura única, cálculo de arqueo (esperado vs contado → diferencia).
- `cash-movement`: ledger append-only de movimientos de efectivo con `balance_after`, tipos enumerados, invariante de sesión abierta, y el helper transaccional reutilizable que será el punto de integración del hot path de venta (C-29).

### Modified Capabilities

_(ninguna — el comportamiento no altera capabilities existentes; `branches` se consume read-only para resolver tenancy y validar `status`)_

## Impact

- **DB (migración nueva, no destructiva)**: `CREATE TABLE cashboxes` + RLS + índices; `CREATE TABLE cash_sessions` + RLS + índice UNIQUE parcial (`cashbox_id WHERE status='open'`); `CREATE TABLE cash_movements` + RLS + índice `(session_id, created_at)`; RPCs `rpc_open_cash_session`, `rpc_close_cash_session`, `rpc_register_cash_movement` (SECURITY DEFINER + `is_account_writer`); helper `c28_register_cash_movement` reutilizable intra-transacción. `npx supabase db push` (CLI, NUNCA el MCP `apply_migration`).
- **Backend** (`backend/`): `cashbox_repository.py`, `cash_session_repository.py`, `routers/cash.py`, `services/cash.py`, schemas + tests (pytest, TDD).
- **Frontend** (`frontend/`): página `/sucursales/:id/caja`, hooks `use-cashboxes`, `use-cash-session`, `use-cash-movements`; componentes `CashSessionPanel`, `OpenSessionForm`, `CashMovementsList`, `CloseSessionDialog`; `database.types.ts` regenerado.
- **Sin impacto** en Edge Functions ni en el importador.
- **Desbloquea / habilita**: C-29 (`v21-quote-salesorder`) consumirá `c28_register_cash_movement` en `SalesOrder.confirm()`; C-30 (cuentas corrientes) comparte el patrón ledger.
- **Depende de**: C-26 (`v21-branch-as-root`) ✅ — `branches` ya es root con `status`/lifecycle.
- **Governance: MEDIO** — implementar con checkpoints; las Open Questions del design (OQ-1..OQ-3) se resuelven con el PO, pero al ser feature nueva sin datos en prod el riesgo es bajo.
