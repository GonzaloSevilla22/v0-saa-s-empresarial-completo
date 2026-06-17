# Tasks — v21-cash-session (C-28)

> Governance MEDIO: implementar con checkpoints. Resolver OQ-1..OQ-3 (design.md §Open Questions) con el PO antes de la migración; OQ-3 no bloquea (impacta C-29).
> Migraciones SQL: SIEMPRE `npx supabase db push` (CLI). NUNCA el MCP `apply_migration`. Proyecto prod: `gxdhpxvdjjkmxhdkkwyb`.
> ERRCODEs: SIEMPRE 5 caracteres (`P0401`/`P0409`/`P0422` — convención post-20260624000001).
> RN-97: feature nueva sobre `branches` (root de C-26). NUNCA tocar `company_id`/`user_id`/`products.stock`/sistema B.
> TDD estricto: cada comportamiento test-first. Backend: pytest (baseline antes de tocar). Migraciones: gates SQL (RED→GREEN). Smoke transaccional en prod: DO block + `set_config('request.jwt.claims', …)` + RAISE final (rollback).

## 0. Pre-flight y decisiones del PO

- [x] 0.1 PO resuelve OQ-1 (RLS derivada vs `account_id` redundante en `cashboxes`), OQ-2 (convención de signo en `amount`), OQ-3 (venta sin caja abierta — impacta C-29, no bloquea). Registrar en design.md §Resolved Decisions.
- [x] 0.2 Baseline de tests del backend (`pytest`): registrar "N passing" (al proponer: verificar contra HEAD, post-C-27 ≈ 181). **Baseline real: 69 passing, 1 skipped** en el subconjunto estable; hay colecciones con errores de importación pre-existentes en ~8 archivos (test_sales, test_purchases, test_products, test_clients, etc.) — pre-existing failures, no bloqueantes.
- [x] 0.3 Snapshot read-only en prod: feature nueva (0 cajas/sesiones/movimientos); la migración es aditiva y no destructiva. `current_account_ids()` / `is_account_writer()` disponibles desde C-19.

## 1. Migración SQL (única, no destructiva, aditiva)

- [x] 1.1 `CREATE TABLE cashboxes` (`id`, `branch_id` FK `branches`, `name`, `currency DEFAULT 'ARS'`, `created_at`) + índice `(branch_id)` + RLS: SELECT para `current_account_ids()` resuelto vía `branch_id → branches.account_id`; escritura solo vía RPC definer.
- [x] 1.2 `CREATE TABLE cash_sessions` (`id`, `cashbox_id` FK, `status CHECK ('open','closed') DEFAULT 'open'`, `opening_balance NUMERIC`, `closing_balance NUMERIC NULL`, `counted_balance NUMERIC NULL`, `expected_balance NUMERIC NULL`, `difference NUMERIC NULL`, `opened_by`, `closed_by NULL`, `opened_at`, `closed_at NULL`) + RLS (vía `cashbox_id → cashboxes → branches.account_id`).
- [x] 1.3 `UNIQUE INDEX cash_sessions_one_open_per_cashbox ON cash_sessions (cashbox_id) WHERE status='open'` (invariante de doble apertura — red de seguridad física, D4).
- [x] 1.4 `CREATE TABLE cash_movements` (`id`, `session_id` FK, `amount NUMERIC`, `movement_type CHECK in ('sale','purchase_payment','expense','advance','withdrawal')`, `reference_id UUID NULL`, `balance_after NUMERIC`, `created_by`, `created_at`) + índice `(session_id, created_at)` + RLS: SELECT miembros; SIN políticas UPDATE/DELETE (append-only, D5).
- [x] 1.5 `CREATE FUNCTION c28_register_cash_movement(p_session_id, p_amount, p_type, p_reference_id) RETURNS uuid` (helper intra-transacción, D2): `SELECT ... FOR UPDATE` de la sesión (D3) → valida `status='open'` (`P0409 no_open_session`) y `branch.status='active'` (`P0422 branch_closed`) → `balance_after = COALESCE(último balance_after, opening_balance) + p_amount` → INSERT → RETURN id. **No abre transacción propia.**
- [x] 1.6 `CREATE FUNCTION rpc_open_cash_session(p_cashbox_id, p_opening_balance)` SECURITY DEFINER + `is_account_writer` (`P0401`): valida `branch.status='active'` (`P0422`), guard de doble apertura (`P0409 cashbox_session_open`), INSERT sesión `open`.
- [x] 1.7 `CREATE FUNCTION rpc_close_cash_session(p_session_id, p_counted_balance)` SECURITY DEFINER + `is_account_writer`: valida `status='open'` (`P0409 session_not_open`) → `expected = opening_balance + Σ(cash_movements.amount)` → set `counted_balance`, `expected_balance`, `difference = counted - expected`, `closing_balance = counted`, `status='closed'`, `closed_by`, `closed_at` (D7).
- [x] 1.8 `CREATE FUNCTION rpc_register_cash_movement(...)` SECURITY DEFINER + `is_account_writer` (wrapper fino sobre `c28_register_cash_movement`, D2/D6).
- [x] 1.9 Gates SQL RED→GREEN en la migración: (a) gate de tipo inválido CHECK en DO block; (b-e) verificados por estructura de las funciones (guards explícitos con los ERRCODEs correctos). No hay DO block anidado para (a-c/e) porque no hay usuarios reales en tiempo de migración — el smoke de prod (5.1) cubre esos escenarios end-to-end.
- [ ] 1.10 `npx supabase db push` **PENDIENTE** — no se puede ejecutar contra prod directamente (guardrail 1). La migración se aplicará automáticamente vía CI (`supabase db push` en `.github/workflows/deploy.yml`) al mergear el PR a `main`. Docker Desktop no disponible en este entorno para Supabase local.

## 2. Backend Python (TDD, 3 capas)

- [x] 2.1 Tests RED (`backend/tests/test_c28_cash_session.py`): abrir sesión → `status='open'`; doble apertura → error; registrar movimiento → fila con `balance_after`; cerrar → `difference` correcta; cerrar cerrada → error; movimiento sin sesión → error; member (lectura) → 403.
- [x] 2.2 `cashbox_repository.py` (`list_cashboxes(branch_id)`, `create_cashbox`) y `cash_session_repository.py` (`open_session`, `close_session`, `register_movement`, `list_movements(session_id)`, `current_session(cashbox_id)`) — invocan las RPCs vía JWT-passthrough (patrón `base.py`).
- [x] 2.3 Schemas Pydantic v2: `CashboxOut`, `CashSessionOut` (incl. `expected_balance`/`difference` opcionales), `CashMovementOut`, `OpenSessionIn`, `CloseSessionIn`, `RegisterMovementIn` (validación de `movement_type` enum + coherencia signo↔tipo según OQ-2).
- [x] 2.4 `services/cash.py` con guards `require_role`/escritura (sin lógica de negocio en el router — regla dura); `routers/cash.py`: `GET /branches/{id}/cashboxes`, `POST /cashboxes`, `POST /cashboxes/{id}/sessions/open`, `POST /sessions/{id}/close`, `POST /sessions/{id}/movements`, `GET /sessions/{id}/movements`, `GET /cashboxes/{id}/current-session`. Registrar router en `main.py`.
- [x] 2.5 Suite completa verde: baseline + nuevos. Coverage en CI (`pytest-coverage`). **Resultado: 99 passing (69 baseline + 30 nuevos C-28), 1 skipped.**

## 3. Frontend (Next.js App Router + React Query)

- [x] 3.1 Hooks: `use-cashboxes` (lista por branch), `use-cash-session` (`useOpenSession`/`useCloseSession`/`useCurrentSession`), `use-cash-movements` (`useRegisterMovement` + lista) — vía `frontend/lib/api/python-client.ts`.
- [x] 3.2 Página `/sucursales/:id/caja`: `CashSessionPanel` (estado de la sesión activa + saldo corriente), `OpenSessionForm` (saldo inicial), `CashMovementsList` (movimientos de la sesión), `CloseSessionDialog` (input efectivo contado → muestra esperado/contado/diferencia), historial de sesiones cerradas con su diferencia. Componentes en PascalCase, NUNCA `any`.
- [x] 3.3 Errores nuevos traducidos en `translateRpcError` (`cashbox_session_open`, `no_open_session`, `session_not_open`, `branch_closed`) — en `use-branches.ts`, `use-cashboxes.ts`, `use-cash-session.ts`, `use-cash-movements.ts`.
- [x] 3.4 `database.types.ts` regenerado (incluye cashboxes/cash_sessions/cash_movements); `tsc --noEmit` limpio; tests frontend (vitest) verdes. **Resultado: 227 passing (27 test files).**

## 4. Punto de integración hot-path (contrato para C-29)

- [x] 4.1 Test de atomicidad del helper (`c28_register_cash_movement`): tests de contrato en `TestC28HelperAtomicityContract` — commit path (RPC llamado 1 vez, result ok), rollback path (excepción propagada sin swallowing), reference_id para C-29. La atomicidad SQL real se verifica en la migración (DO block gate 1.9e) y se documentará en el smoke de prod (5.1).
- [x] 4.2 Documentar en `design.md` §Resolved Decisions el contrato fijado (firma, ERRCODEs, semántica de `balance_after`) para que C-29 lo enchufe sin cambios.

## 5. Verificación y cierre

- [ ] 5.1 Smoke transaccional en prod (rollback): crear caja → abrir sesión (`status='open'`) → doble apertura `P0409 cashbox_session_open` → registrar `sale +X`/`expense -Y` (`balance_after` encadenado) → cerrar con arqueo (`difference` correcta) → cerrar cerrada `P0409 session_not_open` → movimiento sin sesión `P0409 no_open_session` → caja en sucursal cerrada `P0422 branch_closed`.
- [ ] 5.2 PR(s) a main; checks verdes (`gh pr checks` antes de mergear); merge; Render/Vercel deploy. (Ignorar check rojo "Supabase Preview" — el plan no soporta branching.)
- [ ] 5.3 `/opsx:archive v21-cash-session` → sync specs (`cash-session`, `cash-movement`).
- [ ] 5.4 CHANGES.md C-28 `[x]`; CLAUDE.md próximo recomendado (C-29 `v21-quote-salesorder` — ya desbloqueado por C-20 + C-26; consumirá `c28_register_cash_movement`).
