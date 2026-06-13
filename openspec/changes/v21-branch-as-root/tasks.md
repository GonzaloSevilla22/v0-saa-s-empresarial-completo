# Tasks — v21-branch-as-root (C-26)

> Governance ALTO: **no escribir ni aplicar nada hasta que el PO apruebe proposal + design y resuelva OQ-A..OQ-C** (design.md §Open Questions).
> Migraciones SQL: SIEMPRE `npx supabase db push` (CLI). NUNCA el MCP `apply_migration`. Proyecto prod: `gxdhpxvdjjkmxhdkkwyb`.
> ERRCODEs: SIEMPRE 5 caracteres (`P0400`/`P0401`/`P0403`/`P0404`/`P0409`/`P0422` — convención post-20260624000001).
> TDD estricto: cada comportamiento test-first. Backend: pytest (baseline antes de tocar). Migraciones: gates SQL (RED→GREEN). Smoke transaccional en prod: DO block + `set_config('request.jwt.claims', …)` + RAISE final (rollback).

## 0. Pre-flight y decisiones del PO

- [x] 0.1 PO resuelve OQ-A (gate per-branch + CHECK `onHand >= 0`), OQ-B (cierre bloqueado con stock), OQ-C (floor a 0 en reversa de compras). Registrar en design.md §Resolved Decisions. ✅ 2026-06-12 — "dale con lo recomendado" (OQ-A/B/C = sí); registradas con 2 refinamientos de implementación (gate sin-branch contra default operativa; firma de rpc_apply_product_stock_delta conservada con semántica floor).
- [x] 0.2 Baseline de tests del backend (`pytest`): registrar "N passing" (al proponer: 117). ✅ 117 passing confirmado pre-apply.
- [x] 0.3 Snapshot read-only en prod: branches activas (26), filas `branch_stock` negativas (0 — gate del CHECK), transferencias históricas (0), ventas con `branch_id` (0). ✅ Re-verificado 2026-06-12; columnas status / tabla stock_transfers no existen aún.

## 1. Migración SQL (única, no destructiva)

- [x] 1.1 Gate RED→GREEN: 0 filas negativas como assertion DO $$ antes del CHECK. ✅ En `20260625000001` (gate pasó: 0).
- [x] 1.2 `ALTER TABLE branches`: status/opened_at/closed_at + backfill. ✅ Aplicado en prod.
- [x] 1.3 `CREATE TABLE stock_transfers` + índices + RLS (SELECT member; escritura solo vía RPC definer). ✅ Aplicado.
- [x] 1.4 `stock_movements.transfer_id` (FK, índice parcial). ✅ Aplicado.
- [x] 1.5 CHECK `branch_stock_quantity_non_negative`. ✅ Aplicado. **Bug encontrado y corregido por el smoke** (`20260625000002`): el upsert `INSERT VALUES(delta) ON CONFLICT` del helper violaba el CHECK en la fase INSERT con delta negativo (Postgres valida los CHECK de la fila propuesta ANTES de resolver el conflicto) — toda venta rompía. Fix: UPDATE-then-INSERT en `c21_apply_branch_stock_delta`. Ventana de ~4 min sin tráfico (0 ventas).
- [x] 1.6 `rpc_open_branch` / `rpc_close_branch` con guards + bloqueos (branch_has_stock, last_active_branch). ✅ Smoke: P0409 en ambos casos.
- [x] 1.7 `rpc_transfer_stock` reescrito: crea `stock_transfers` + 2 movements con `transfer_id`; valida lifecycle. ✅ Smoke: 2 movements vinculados.
- [x] 1.8 Validación `branch_closed` (P0422) en sale(_v2), adjust_branch_stock, apply_product_stock_delta. ✅ Smoke: P0422 en venta contra cerrada.
- [x] 1.9 Gate per-branch (OQ-A) en sale(_v2); sin branch → gate contra default operativa (Resolved Decisions). ✅ Smoke: P0409 en B sin stock; venta con B 3→2; sin branch default 35→31.
- [x] 1.10 OQ-C: floor a 0 + movement `floor_on_purchase_delete` (firma conservada, `p_allow_negative` = floor-mode — ver Resolved Decisions). Caller sin cambios. ✅ En `20260625000001` §7.
- [x] 1.11 `npx supabase db push` (x2: 01 + fix 02); advisors 0 ERRORs (WARN genérico de SECURITY DEFINER en open/close = igual que todos los RPCs del API). ✅

## 2. Backend Python (TDD)

- [x] 2.1 Tests RED: open/close llaman las RPCs; list_transfers consulta stock_transfers (origen O destino, por cuenta, desc); endpoints + member 403. ✅ `backend/tests/test_c26_branch_lifecycle.py` — RED 7 failed → GREEN. (`StockRepository.transfer` no requirió cambios: el `transfer_id` viaja en el jsonb del RPC.)
- [x] 2.2 Repos + schemas (`BranchOut` + status/opened_at/closed_at opcionales; `BranchLifecycleOut`; `StockTransferOut`). ✅
- [x] 2.3 Endpoints `POST /branches/{id}/open|close`, `GET /branches/{id}/transfers` (router → service `require_role` → repo; el RPC además exige `is_account_writer`). ✅
- [x] 2.4 `purchase_repository`: SIN cambios — la firma del RPC se conservó (Resolved Decisions OQ-C); `p_allow_negative=TRUE` ahora floorea con trazabilidad. ✅
- [x] 2.5 Suite completa verde: **124/124** (baseline 117 + 7 nuevos). ✅

## 3. Frontend

- [x] 3.1 `use-branches`: select + map con status/opened_at/closed_at; `useOpenBranch`/`useCloseBranch`; `use-branch-transfers` (nuevo, vía `GET /branches/{id}/transfers`). ✅
- [x] 3.2 UI: badge Activa/Cerrada + botón Cerrar/Reabrir con confirmación en `BranchList` (no existe página `/sucursales/:id` — el detalle vive en el listado); historial de transferencias (`BranchTransfersList`) + badge en `/sucursales/:id/stock`. ✅
- [x] 3.3 Errores nuevos traducidos en `translateRpcError` (`branch_has_stock`, `last_active_branch`, `branch_closed`). ✅
- [x] 3.4 `database.types.ts` regenerado (incluye stock_transfers + RPCs nuevos); `tsc --noEmit` limpio; **203/203 tests frontend** (vitest — ojo: `npx jest` baja un jest global sin config; usar `npm test`). ✅

## 4. Verificación y cierre

- [x] 4.1 Smoke transaccional en prod (rollback): venta en B sin stock → P0409; transferencia → `stock_transfers` + 2 movements con `transfer_id`; venta con B 3→2; venta sin branch default 35→31; close con stock → P0409; venta en cerrada → P0422; close última operativa → P0409. ✅ (El smoke detectó y se corrigió el bug del upsert vs CHECK — ver 1.5.)
- [ ] 4.2 PR(s) a main; checks verdes; merge (autorizado si CI pasa); Render/Vercel deploy.
- [ ] 4.3 `/opsx:archive v21-branch-as-root` → sync specs (`branches`, `branch-stock`, `stock-transfer`).
- [ ] 4.4 CHANGES.md C-26 `[x]`; CLAUDE.md próximo recomendado (C-27 fiscal-profile — requiere PA-22 del PO — o C-28 cash-session).
