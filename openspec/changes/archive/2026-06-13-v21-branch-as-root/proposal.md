# Proposal — v21-branch-as-root (C-26)

## Why

`Branch` hoy es poco más que una etiqueta (`name`, `address`, `is_active`): no tiene ciclo de vida operacional, las transferencias de stock existen solo como una RPC sin identidad propia (los movimientos `transfer_out`/`transfer_in` no comparten un id que los una), y `branch_stock` no tiene ningún invariante — una sucursal puede quedar con stock negativo. El modelo de dominio V2 (DEC-19) exige `Branch` como Aggregate Root real porque toda la Fase 7 se construye encima: C-27 ata el punto de venta AFIP a una Branch, C-28 ata cada Cashbox a una Branch, C-29 crea documentos con `branch_id`. Es el momento óptimo: post-C-21 `branch_stock` es el único ledger, y en producción **ninguna cuenta opera multi-branch todavía** (26 cuentas × 1 branch, 0 transferencias, 0 ventas con `branch_id` de 142) — los invariantes nuevos no rompen a nadie.

## What Changes

- **Lifecycle de Branch**: columnas `status TEXT CHECK ('active','closed')`, `opened_at`, `closed_at` en `branches` + comandos `open()`/`close()` (RPCs + endpoints backend). `status` es estado **operacional** (¿puede operar hoy?), independiente de `is_active` (existencia / soft-delete).
- **BREAKING — Operar contra una sucursal cerrada falla**: ventas, compras, ajustes y transferencias que referencien una branch con `status = 'closed'` retornan error `P0422 branch_closed`. (Hoy solo se valida `is_active`.)
- **BREAKING (multi-branch) — Invariante `onHand >= 0` por sucursal**: `CHECK (quantity >= 0)` en `branch_stock` + gate de venta per-branch cuando la operación lleva `branch_id` explícito. Reemplaza la política transitoria de C-21 (gate global con negativos transitorios permitidos). Sin impacto en cuentas mono-branch: la venta sin `branch_id` sigue descontando de la default branch, donde vive todo el stock (gate global ≡ gate per-branch en ese caso). Sujeto a OQ-A del design.
- **StockTransfer como entidad de primer nivel**: tabla `stock_transfers` (`id`, `account_id`, `product_id`, `from_branch_id`, `to_branch_id`, `quantity`, `status`, `created_by`, `created_at`) — `rpc_transfer_stock` se reescribe para crearla y vincular ambos `stock_movements` vía `transfer_id`; historial consultable por sucursal.
- **Backend Python**: `BranchRepository` con `open_branch`/`close_branch`/`list_transfers`; router `branches` con los endpoints nuevos; `StockRepository.transfer` retorna el `transfer_id`.
- **UI `/sucursales/:id`**: badge de estado, botón Abrir/Cerrar (con confirmación), listado de transferencias de la sucursal.
- Cierre de branch **bloqueado si tiene stock** (`Σ branch_stock de la branch > 0`) — forzar transferencia previa (sujeto a OQ-B).

## Capabilities

### New Capabilities

_(ninguna — todo el comportamiento extiende capabilities existentes)_

### Modified Capabilities

- `branches`: lifecycle operacional (status/opened_at/closed_at, comandos open/close, regla de cierre con stock, validación de branch cerrada en operaciones).
- `branch-stock`: invariante `onHand >= 0` (CHECK) + gate de venta per-branch cuando la operación lleva `branch_id` explícito (reemplaza el requirement transitorio de C-21 que permitía negativos).
- `stock-transfer`: la transferencia pasa de "dos movimientos sueltos" a entidad `StockTransfer` con identidad, estado e historial; ambos `stock_movements` referencian el `transfer_id`.

## Impact

- **DB (migración nueva)**: `ALTER TABLE branches` (3 columnas + CHECK + backfill `status='active'`, `opened_at=created_at`); `CREATE TABLE stock_transfers` + RLS; `ALTER TABLE stock_movements ADD transfer_id UUID NULL FK`; `ALTER TABLE branch_stock ADD CHECK (quantity >= 0)` (gate previo: 0 filas negativas, verificado 2026-06-12); reescritura de `rpc_transfer_stock`, `rpc_create_sale_operation(_v2)` (validación branch cerrada + gate per-branch), `rpc_create_purchase_operation(_v2)` y `rpc_adjust_branch_stock`/`rpc_apply_product_stock_delta` (validación branch cerrada); RPCs nuevas `rpc_open_branch`/`rpc_close_branch`.
- **Backend** (`backend/`): `branch_repository.py`, `stock_repository.py`, `routers/branches.py`, `routers/stock.py`, schemas + tests (pytest, TDD).
- **Frontend** (`frontend/`): página `/sucursales/:id` (estado + acciones + historial de transferencias), hook `use-branches`, `use-branch-stock`; `database.types.ts` regenerado.
- **Sin impacto** en Edge Functions ni en el importador (no tocan branches/transfer).
- **Desbloquea**: C-27 (`v21-fiscal-profile` — punto de venta por branch), C-28 (`v21-cash-session` — Cashbox por branch), C-29 (`v21-quote-salesorder`).
- **Governance: ALTO** — este proposal + design requieren revisión del PO antes del apply; las Open Questions del design (OQ-A..OQ-C) deben resolverse primero.
