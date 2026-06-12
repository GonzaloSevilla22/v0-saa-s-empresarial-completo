# Tasks — v21-branch-as-root (C-26)

> Governance ALTO: **no escribir ni aplicar nada hasta que el PO apruebe proposal + design y resuelva OQ-A..OQ-C** (design.md §Open Questions).
> Migraciones SQL: SIEMPRE `npx supabase db push` (CLI). NUNCA el MCP `apply_migration`. Proyecto prod: `gxdhpxvdjjkmxhdkkwyb`.
> ERRCODEs: SIEMPRE 5 caracteres (`P0400`/`P0401`/`P0403`/`P0404`/`P0409`/`P0422` — convención post-20260624000001).
> TDD estricto: cada comportamiento test-first. Backend: pytest (baseline antes de tocar). Migraciones: gates SQL (RED→GREEN). Smoke transaccional en prod: DO block + `set_config('request.jwt.claims', …)` + RAISE final (rollback).

## 0. Pre-flight y decisiones del PO

- [ ] 0.1 PO resuelve OQ-A (gate per-branch + CHECK `onHand >= 0`), OQ-B (cierre bloqueado con stock), OQ-C (floor a 0 en reversa de compras). Registrar en design.md §Resolved Decisions.
- [ ] 0.2 Baseline de tests del backend (`pytest`): registrar "N passing" (al proponer: 117).
- [ ] 0.3 Snapshot read-only en prod: branches activas (26), filas `branch_stock` negativas (0 — gate del CHECK), transferencias históricas (0), ventas con `branch_id` (0).

## 1. Migración SQL (única, no destructiva)

- [ ] 1.1 Gate RED→GREEN: `SELECT count(*) FROM branch_stock WHERE quantity < 0` == 0 como assertion DO $$ antes del CHECK.
- [ ] 1.2 `ALTER TABLE branches`: `status TEXT NOT NULL DEFAULT 'active' CHECK (status IN ('active','closed'))`, `opened_at TIMESTAMPTZ`, `closed_at TIMESTAMPTZ`; backfill `opened_at = created_at`.
- [ ] 1.3 `CREATE TABLE stock_transfers` (id, account_id FK, product_id FK, from_branch_id FK, to_branch_id FK, quantity numeric(15,4) > 0, status TEXT DEFAULT 'completed', created_by, created_at) + índices (account_id, from/to_branch_id) + RLS (SELECT member de la cuenta; escritura solo vía RPC definer).
- [ ] 1.4 `ALTER TABLE stock_movements ADD COLUMN transfer_id UUID NULL REFERENCES stock_transfers(id)`.
- [ ] 1.5 `ALTER TABLE branch_stock ADD CONSTRAINT branch_stock_quantity_non_negative CHECK (quantity >= 0)` (tras gate 1.1).
- [ ] 1.6 `rpc_open_branch` / `rpc_close_branch`: guards auth + `is_account_writer` + cuenta propia; close bloquea con stock (`P0409 branch_has_stock`) y última activa (`P0409 last_active_branch`); timestamps.
- [ ] 1.7 Reescribir `rpc_transfer_stock`: crea `stock_transfers` + 2 movements con `transfer_id`; valida `status='active'` en ambas branches (`P0422 branch_closed`); ERRCODEs 5 chars.
- [ ] 1.8 Validación `branch_closed` en RPCs operativas: `rpc_create_sale_operation(_v2)` (p_branch_id), `rpc_adjust_branch_stock`, `rpc_apply_product_stock_delta` (p_branch_id).
- [ ] 1.9 Gate per-branch (OQ-A): en `rpc_create_sale_operation(_v2)` con `p_branch_id` explícito, validar `branch_stock.quantity >= qty` de ESA branch (`P0409 insufficient_branch_stock`); sin `p_branch_id`, gate global como hoy.
- [ ] 1.10 OQ-C: `rpc_apply_product_stock_delta` — quitar `p_allow_negative`; floor a 0 + movement `floor_on_purchase_delete` cuando la reversa excede el stock de la branch. Actualizar el caller (`purchase_repository`).
- [ ] 1.11 Aplicar con `npx supabase db push`; correr `get_advisors` (0 ERRORs nuevos).

## 2. Backend Python (TDD)

- [ ] 2.1 Tests RED: `BranchRepository.open_branch`/`close_branch` llaman las RPCs; `list_transfers(branch_id)` consulta `stock_transfers` por cuenta; `StockRepository.transfer` retorna `transfer_id`.
- [ ] 2.2 Implementar repos + schemas Pydantic (`BranchOut` con status/opened_at/closed_at; `StockTransferOut`).
- [ ] 2.3 Endpoints: `POST /branches/{id}/open`, `POST /branches/{id}/close`, `GET /branches/{id}/transfers` (router → service con `require_role` → repo).
- [ ] 2.4 `purchase_repository`: adaptar la reversa al RPC sin `p_allow_negative` (OQ-C). Actualizar tests de delete.
- [ ] 2.5 Suite completa verde (baseline + nuevos).

## 3. Frontend

- [ ] 3.1 `use-branches`: estado del lifecycle + mutations open/close. `use-branch-transfers` (nuevo) para el historial.
- [ ] 3.2 `/sucursales/:id`: badge de estado, botón Abrir/Cerrar con confirmación (y mensaje claro si `branch_has_stock`), listado de transferencias.
- [ ] 3.3 Manejo de errores nuevos en UI (`branch_closed`, `branch_has_stock`, `insufficient_branch_stock` per-branch) — los mensajes ya llegan con detail útil post-#163.
- [ ] 3.4 Regenerar `database.types.ts` (bash, no PS `>`); `tsc --noEmit` limpio.

## 4. Verificación y cierre

- [ ] 4.1 Smoke transaccional en prod (rollback): open/close, close con stock bloquea, venta con branch explícita sin stock local falla `P0409`, transferencia crea `stock_transfers` + 2 movements con `transfer_id`, venta en branch cerrada falla `P0422`.
- [ ] 4.2 PR(s) a main; checks verdes; merge (autorizado si CI pasa); Render/Vercel deploy.
- [ ] 4.3 `/opsx:archive v21-branch-as-root` → sync specs (`branches`, `branch-stock`, `stock-transfer`).
- [ ] 4.4 CHANGES.md C-26 `[x]`; CLAUDE.md próximo recomendado (C-27 fiscal-profile — requiere PA-22 del PO — o C-28 cash-session).
