# Tasks: bank-reconciliation

## 1. Migración SQL — schema + RPCs (aditiva, gates TDD embebidos)

- [x] 1.1 Nombrar la migración con timestamp > última existente (`ls supabase/migrations | sort | tail -1`) — `2026XXXXXXXXXX_bank_reconciliation.sql`
- [x] 1.2 Tablas `bank_statement_imports` + `bank_statement_lines` (append-only, `account_id` denormalizado, FKs, índices) + RLS SELECT-only (`account_id IN (SELECT current_account_ids())`)
- [x] 1.3 Tabla `reconciliation_sessions` (FSM CHECK `open/closed`, saldos, `close_reason`, opened/closed by/at) + índice UNIQUE parcial anti doble-apertura `ON (bank_account_id) WHERE status = 'open'` + RLS SELECT-only
- [x] 1.4 Tabla `reconciliation_matches` (`match_group`, `status active/undone`, `undo_reason`, matched/undone by/at) + índice parcial `(statement_line_id) WHERE status='active'` y `(bank_movement_id) WHERE status='active'` + RLS SELECT-only
- [x] 1.5 `ALTER TABLE bank_movements ADD COLUMN reconciliation_status TEXT NOT NULL DEFAULT 'unreconciled' CHECK (...)`, `reconciled_at TIMESTAMPTZ NULL` (aditivo, sin reescritura)
- [x] 1.6 Extender CHECK de `operation_idempotency.operation_kind` con `bank_statement_import` (DROP+ADD idempotente, misma migración — regla C-30)
- [x] 1.7 RPC `rpc_import_bank_statement(p_idempotency_key, p_bank_account_id, p_file_name, p_file_hash, p_lines jsonb)` — valida cuenta activa (`P0412`), writer (`P0401`), cap 5.000 líneas, dedupe por `file_hash` (replay), inserta import + líneas atómico
- [x] 1.8 RPC `rpc_open_reconciliation_session(p_bank_account_id, p_period_from, p_period_to, p_statement_closing_balance)` — anti doble-apertura (`P0409`)
- [x] 1.9 RPC `rpc_close_reconciliation_session(p_session_id, p_close_reason)` — calcula `ledger_closing_balance` por `value_date <= period_to` y `difference`; exige motivo si ≠ 0 (`P0431`); `P0432` si ya cerrada
- [x] 1.10 RPC `rpc_create_reconciliation_match(p_session_id, p_statement_line_ids uuid[], p_bank_movement_ids uuid[])` — grupo atómico: valida sesión open (`P0432`), Σ montos (`P0433`), sin match activo previo (`P0434`), misma cuenta; setea `matched` + `reconciled_at` en los movimientos
- [x] 1.11 RPC `rpc_undo_reconciliation_match(p_match_group, p_undo_reason)` — exige motivo (`P0431`), sesión open (`P0432`); marca grupo `undone` y revierte movimientos a `unreconciled` (sin DELETE)
- [x] 1.12 `CREATE OR REPLACE rpc_register_bank_movement` — tipos manuales ampliados a `{transfer_in, transfer_out, manual_adjustment, fee, tax_debit, interest}`; `card_settlement` sigue `P0410` (verificar que no queden overloads viejos — lección 42725)
- [x] 1.13 Gates TDD al final de la migración: solo en DB vacía (`count(*)=0 FROM accounts`), sub-bloques `BEGIN/EXCEPTION` (sin SAVEPOINT), `WHEN OTHERS` con discriminación de mensaje, anchor sintético sin tocar `auth.users` — cubrir: import idempotente, doble-apertura, cierre con diferencia sin motivo, match con sumas desbalanceadas, undo sin motivo, `fee` manual aceptado, `card_settlement` manual rechazado

## 2. Backend FastAPI — 3 capas con TDD (RED → GREEN → TRIANGULATE)

- [x] 2.1 Safety net: correr suite backend completa y registrar baseline antes de tocar nada
- [x] 2.2 ERRCODEs nuevos `P0430–P0434` mapeados en `backend/core/errors.py` con mensajes en español (tests primero)
- [x] 2.3 Schemas Pydantic v2: `StatementImportIn` (líneas normalizadas: `line_no`, `value_date`, `description`, `amount`, `balance?`; validación de shape y cap), `SessionOut`, `MatchIn/Out`, `SuggestionOut`
- [x] 2.4 `bank_reconciliation_repository.py` — llamadas a las 5 RPCs + queries de lectura (líneas por import con estado derivado vía EXISTS, movimientos filtrables por `reconciliation_status`, sugerencias 1:1: monto exacto + `value_date` ±3 días, ambos sin match activo)
- [x] 2.5 `bank_reconciliation` service — orquestación + guards; sin lógica de dominio duplicada (la transaccionalidad vive en las RPCs)
- [x] 2.6 Router `bank_reconciliation.py`: `POST /bank-accounts/{id}/statement-imports`, `GET .../statement-imports/{id}/lines`, `POST /bank-accounts/{id}/reconciliation-sessions`, `GET /reconciliation-sessions/{id}` (+ líneas/movimientos pendientes), `GET .../suggestions`, `POST .../matches`, `POST .../matches/{group}/undo`, `POST .../close`
- [x] 2.7 Tests por endpoint: happy path + `P0401` (read-only 403) + errores de dominio (409/422 según mapeo) + replay idempotente del import — mínimo 2 casos por comportamiento

## 3. Frontend — UI de conciliación

- [x] 3.1 Hook `use-bank-reconciliation` (React Query): imports, sesión activa, líneas/movimientos pendientes, sugerencias, mutaciones (import, open, match, undo, close) con invalidación de cache
- [x] 3.2 Parser de extracto en el cliente reutilizando el pipeline CSV existente → filas normalizadas + `file_hash` (SHA-256 del archivo); UI documenta el shape esperado (fecha, descripción, monto, saldo opcional)
- [x] 3.3 Página de conciliación en el detalle de cuenta bancaria: wizard de import → panel doble (extracto vs. movimientos, filtros por estado) → botón sugerencias (confirmación explícita) → match/undo manual con selección múltiple (1:N / N:1)
- [x] 3.4 Cierre de sesión: resumen (saldo extracto vs. ledger, diferencia), campo motivo obligatorio si ≠ 0, estado cerrado read-only
- [x] 3.5 Registrar cargo del extracto ("solo anotar"): acceso rápido desde una línea sin match a `rpc_register_bank_movement` con tipo `fee`/`tax_debit`/`interest` precargado
- [x] 3.6 Tests frontend (vitest, `npm test` — nunca `npx jest`): hook con API mockeada + componentes clave

## 4. Verificación y cierre

- [x] 4.1 Suite backend completa verde desde la raíz del repo (`python -m pytest backend/tests`) — comparar contra baseline 2.1
- [x] 4.2 Suite frontend completa verde
- [ ] 4.3 PR `feat/bank-reconciliation` off main actualizado (verificar merges previos — regla rama-nueva-por-cambio); CI `validate-kpis` verde (único validador de la migración)
- [ ] 4.4 Post-merge: verificación read-only en prod vía MCP (tablas + RLS + RPCs presentes; `rpc_register_bank_movement` acepta `fee` y rechaza `card_settlement`)
- [ ] 4.5 Smoke transaccional en prod con rollback (patrón DO block + `set_config('request.jwt.claims', ...)`): import chico → open → match 1:1 → undo → close, todo revertido
- [ ] 4.6 Actualizar CHANGES.md (estado C3) y guardar progreso en engram (`opsx/bank-reconciliation/apply`)
