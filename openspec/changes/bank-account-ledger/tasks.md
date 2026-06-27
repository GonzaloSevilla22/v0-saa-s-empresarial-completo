# Tasks — bank-account-ledger (C1)

> **DB-level TDD.** Cada tabla/helper/RPC se construye como un ciclo RED→GREEN→TRIANGULATE→REFACTOR usando bloques de aserción SQL (`DO $$ ... $$` con SAVEPOINT/ROLLBACK) dentro del DO-block de gates de la migración, espejando el patrón de `20260701000001_c28_cash_session.sql` §1.9.
> **APPLY**: la migración se aplica SOLO vía `npx supabase db push` (CI al mergear). NUNCA MCP `apply_migration`. El apply-phase NO ejecuta ningún comando de DB.
> **Archivo único**: `supabase/migrations/20260804000002_bank_account_ledger.sql` (timestamp libre verificado; última existente `20260803000003`).
> **ERRCODEs**: P0401 (escritor no autorizado), P0410 (movement_type reservado en RPC manual), P0411 (CBU inválido), P0412 (cuenta no encontrada/inactiva).

## 1. Migración: esqueleto + tabla `bank_accounts` (capability `bank-account`)

- [x] 1.1 Crear `supabase/migrations/20260804000002_bank_account_ledger.sql` con el header espejo de C-28: CHANGE, principio "dos ledgers" (operacional vs `1110` contable), ERRCODEs (P0401/P0410/P0411/P0412), GOVERNANCE MEDIO, APPLY (`npx supabase db push`, nunca MCP), bloque ROLLBACK (DROP RPCs+helper, DROP `bank_movements` luego `bank_accounts`), VERIFICATION (`information_schema`).
- [x] 1.2 **RED**: gate que afirma que `INSERT INTO bank_accounts` con `cbu = '12345'` viola el `CHECK` de CBU (esperar `check_violation`). (Falla: tabla aún no existe.)
- [x] 1.3 **GREEN**: `CREATE TABLE bank_accounts` (id uuid PK, `account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE`, name, bank_name, `cbu text`, `alias text`, `currency text DEFAULT 'ARS'`, `opening_balance numeric(14,2) DEFAULT 0`, `opening_date date`, `is_active bool DEFAULT true`, `created_at timestamptz DEFAULT now()`) + `CHECK (cbu IS NULL OR cbu ~ '^[0-9]{22}$')` (D7). Re-ejecutar gate 1.2 → GREEN.
- [x] 1.4 **TRIANGULATE**: segundo gate — `INSERT` con `cbu = NULL` y `INSERT` con un CBU válido de 22 dígitos ambos PASAN (el CHECK solo rechaza el formato malo, no NULL ni el válido).
- [x] 1.5 Índice `bank_accounts_account_id_idx ON bank_accounts (account_id)` (D2/RLS directa).
- [x] 1.6 **REFACTOR**: `COMMENT ON TABLE/COLUMN` (greenfield, org-level, no branch-scoped; CBU formato sin DV). Tests siguen verdes.

## 2. RLS de `bank_accounts` (capability `bank-account`)

- [x] 2.1 **RED**: gate de aislamiento — con dos `accounts` (A y B), afirmar que un SELECT en contexto de B NO ve la fila de A. (Falla: RLS aún no habilitada.)
- [x] 2.2 **GREEN**: `ALTER TABLE bank_accounts ENABLE ROW LEVEL SECURITY` + `CREATE POLICY bank_accounts_select FOR SELECT USING (account_id IN (SELECT public.current_account_ids()))` (D1/D5). Sin policy de escritura (deliberado). Re-ejecutar 2.1 → GREEN.
- [x] 2.3 **TRIANGULATE**: gate que afirma que en contexto de A, A SÍ ve su propia fila (la policy no bloquea al dueño).
- [x] 2.4 **TRIANGULATE (escritura directa bloqueada)**: gate que afirma que `INSERT INTO bank_accounts` por el rol `authenticated` (sin RPC) es rechazado por RLS (no hay policy de INSERT).

## 3. Tabla `bank_movements` + RLS (capability `bank-movement`)

- [x] 3.1 **RED**: gate que afirma que `INSERT INTO bank_movements` con `movement_type = 'foo'` viola el CHECK del enum (esperar `check_violation`). (Falla: tabla no existe.)
- [x] 3.2 **GREEN**: `CREATE TABLE bank_movements` (id uuid PK, `bank_account_id uuid NOT NULL REFERENCES bank_accounts(id) ON DELETE CASCADE`, `account_id uuid NOT NULL REFERENCES accounts(id) ON DELETE CASCADE` [denormalizado, D2], `amount numeric(14,2) NOT NULL`, `balance_after numeric(14,2) NOT NULL`, `movement_type text NOT NULL CHECK (movement_type IN ('transfer_in','transfer_out','card_settlement','fee','tax_debit','interest','manual_adjustment'))` [enum completo, D3], `value_date date`, `branch_id uuid REFERENCES branches(id)` [nullable, analítica], `source_doc_type text`, `source_doc_ref uuid`, `description text`, `created_at timestamptz DEFAULT now()`). Re-ejecutar 3.1 → GREEN.
- [x] 3.3 **TRIANGULATE**: gate que afirma que los 7 `movement_type` del enum se insertan OK (pertenencia al enum, incluidos los reservados a nivel tabla).
- [x] 3.4 Índices: `bank_movements_bank_account_value_date_idx (bank_account_id, value_date DESC)`, `bank_movements_account_id_idx (account_id)` (D2).
- [x] 3.5 **RED**: gate de aislamiento — B no ve los `bank_movements` de A. (Falla: RLS no habilitada.)
- [x] 3.6 **GREEN**: `ENABLE ROW LEVEL SECURITY` + `CREATE POLICY bank_movements_select FOR SELECT USING (account_id IN (SELECT public.current_account_ids()))` (D2 — denormalizado, sin subquery por fila). Sin policy de UPDATE/DELETE/INSERT (append-only, D5). Re-ejecutar 3.5 → GREEN.
- [x] 3.7 **TRIANGULATE (escritura directa bloqueada)**: gate que afirma que `INSERT/UPDATE/DELETE` directo de `authenticated` sobre `bank_movements` es rechazado por RLS.
- [x] 3.8 **REFACTOR**: `COMMENT ON TABLE/COLUMN` (append-only, `account_id` denormalizado para RLS, tipos reservados card_settlement/fee/tax_debit/interest documentados, `value_date` ≠ `created_at`).

## 4. Helper intra-tx `_register_bank_movement` (contrato C1→C2, capability `bank-movement`)

- [x] 4.1 **RED**: gate que afirma que llamar `_register_bank_movement(...)` falla (función no existe).
- [x] 4.2 **GREEN**: `CREATE FUNCTION _register_bank_movement(p_bank_account_id, p_amount, p_type, p_source_doc_type, p_source_doc_ref, p_value_date, p_branch_id, p_description) RETURNS uuid` — `SECURITY DEFINER`, `SET search_path = public`, NO abre transacción propia; `SELECT ... FOR UPDATE` sobre `bank_accounts`; `balance_after = COALESCE(MAX(bm.balance_after), ba.opening_balance) + p_amount`; copia `account_id` de la cabecera; INSERT append-only (D4). Gate: registra `+5000` sobre `opening_balance=10000` → `balance_after=15000`.
- [x] 4.3 **TRIANGULATE (secuencia signada)**: gate que registra `+500`, `-200`, `+300` sobre `opening_balance=1000` y afirma `balance_after = 1500, 1300, 1600` (signo +/− y acumulación correctos).
- [x] 4.4 **TRIANGULATE (atomicidad)**: gate que registra un movimiento dentro de un SAVEPOINT y luego hace ROLLBACK del SAVEPOINT, afirmando que no queda fila (el helper no abre su propia transacción).
- [x] 4.5 **GREEN (higiene)**: `REVOKE ALL ON FUNCTION _register_bank_movement(...) FROM PUBLIC` + REVOKE de `anon`/`authenticated` (callable solo desde RPCs SECURITY DEFINER de C1/C2). Gate: afirma que `authenticated` no tiene EXECUTE.
- [x] 4.6 **REFACTOR**: `COMMENT ON FUNCTION` (espejo de `c28_register_cash_movement`; contrato C1→C2; REVOKE de PUBLIC).

## 5. RPCs públicas `rpc_create_bank_account` / `rpc_update_bank_account` (capability `bank-account`)

- [x] 5.1 **RED**: gate que afirma que `rpc_create_bank_account(...)` no existe aún.
- [x] 5.2 **GREEN**: `CREATE FUNCTION rpc_create_bank_account(p_name, p_bank_name, p_cbu, p_alias, p_currency, p_opening_balance, p_opening_date) RETURNS jsonb` — SECURITY DEFINER, SET search_path; resuelve `account_id` vía `current_account_ids()`; guard `is_account_writer` → `P0401`; valida CBU (`^[0-9]{22}$` cuando no NULL) → `P0411`; INSERT; devuelve `jsonb`. `REVOKE FROM PUBLIC, anon; GRANT EXECUTE TO authenticated`.
- [x] 5.3 **TRIANGULATE (guard)**: gate que afirma que un usuario sin `is_account_writer` recibe `P0401` y no se inserta fila.
- [x] 5.4 **TRIANGULATE (CBU)**: gate que afirma que `p_cbu = '12345'` retorna `P0411`; y que `p_cbu = NULL` y un CBU de 22 dígitos crean la cuenta OK.
- [x] 5.5 **GREEN**: `CREATE FUNCTION rpc_update_bank_account(p_bank_account_id, p_name, p_bank_name, p_alias, p_is_active) RETURNS jsonb` — guard `is_account_writer` (P0401); `P0412` si la cuenta no existe / no pertenece a la cuenta; UPDATE de campos editables (incl. soft-deactivate `is_active`). REVOKE/GRANT igual. Gate: desactivar (`is_active=false`) persiste.
- [x] 5.6 **TRIANGULATE (update guard)**: gate que afirma que un no-escritor recibe `P0401` en `rpc_update_bank_account` y la fila no cambia.

## 6. RPC pública `rpc_register_bank_movement` (carga manual, capability `bank-movement`)

- [x] 6.1 **RED**: gate que afirma que `rpc_register_bank_movement(...)` no existe aún.
- [x] 6.2 **GREEN**: `CREATE FUNCTION rpc_register_bank_movement(p_idempotency_key, p_bank_account_id, p_amount, p_type, p_value_date, p_branch_id, p_description) RETURNS jsonb` — SECURITY DEFINER, SET search_path; guard `is_account_writer` → `P0401`; valida `p_type IN ('transfer_in','transfer_out','manual_adjustment')` (subconjunto manual) → `P0410` si no; resuelve+valida cuenta activa (`is_active`) → `P0412`; idempotencia `operation_idempotency (operation_kind='bank_movement')` con `ON CONFLICT DO NOTHING` (D6); delega a `_register_bank_movement`; devuelve `jsonb` con `movement_id`/`balance_after`/`replayed`. `REVOKE FROM PUBLIC, anon; GRANT EXECUTE TO authenticated`. Gate: una transferencia manual válida inserta y devuelve `replayed=false`.
- [x] 6.3 **TRIANGULATE (tipo reservado)**: gate que afirma que `p_type = 'card_settlement'` retorna `P0410` y no inserta fila (solo el subconjunto manual es aceptado — D3).
- [x] 6.4 **TRIANGULATE (guard escritor)**: gate que afirma que un no-escritor recibe `P0401` y no inserta fila.
- [x] 6.5 **TRIANGULATE (cuenta inactiva)**: gate que afirma que registrar sobre una cuenta con `is_active=false` retorna `P0412`.
- [x] 6.6 **TRIANGULATE (idempotencia)**: gate que llama dos veces con la misma `idempotency_key` y afirma `replayed=true` en la segunda + una sola fila en `bank_movements`.
- [x] 6.7 **REFACTOR**: `COMMENT ON FUNCTION` en las 3 RPCs (guard, subconjunto manual, idempotencia, P04xx). Tests verdes.

## 7. Gates finales + sincronización del roadmap

- [x] 7.1 Consolidar todos los gates en el DO-block final de la migración (estilo C-28 §1.9): SAVEPOINTs por sub-gate, ROLLBACK total de los datos de prueba, `RAISE NOTICE` de resumen. Verificar que el archivo aplica limpio en local de quien implemente (sin ejecutar en prod).
- [x] 7.2 Verificar que el principio "C1 no postea al journal" se cumple: gate (o aserción documental) de que registrar un `bank_movement` no crea filas en `journal_lines` con `account_code='1110'`.
- [ ] 7.3 `CHANGES.md` ya registra `bank-account-ledger` como C1 de la secuencia BankReconciliation (hecho en propose). Tras el archive, marcar `[x]` y agregar specs sincronizadas (`bank-account`, `bank-movement`).
- [x] 7.4 Completar la tabla **TDD Cycle Evidence** (abajo) durante el apply.

## TDD Cycle Evidence

> El apply-phase completa esta tabla a medida que ejecuta cada ciclo. Cada gate mapea a un comportamiento del spec.

| Task | Gate / Comportamiento cubierto | Layer | Safety Net | RED | GREEN | TRIANGULATE | REFACTOR |
|------|-------------------------------|-------|-----------|-----|-------|-------------|----------|
| 1.x | `bank_accounts` existe; CHECK de CBU rechaza no-22-dígitos; NULL y CBU válido pasan | SQL gate (a)+(b) | greenfield (0 filas) | 1.2 → gate (a) | 1.3 tabla creada | 1.4 → gate (b) | 1.6 COMMENT |
| 2.x | RLS `bank_accounts`: sin policy escritura → INSERT directo bloqueado | SQL gate (c) | — | 2.1 (sin RLS → gate fallaría) | 2.2 RLS habilitada | 2.3/2.4 → gate (c) pg_policies=0 | — |
| 3.x | `bank_movements` enum CHECK (7 tipos); RLS por account_id denormalizado; append-only | SQL gate (d)+(e)+(f) | — | 3.1 → gate (d); 3.5 → gate (f) | 3.2/3.6 tabla+RLS | 3.3 → gate (e); 3.7 → gate (f) | 3.8 COMMENT |
| 4.x | `_register_bank_movement` balance_after; signo +/−; atomicidad; EXECUTE revocado | SQL gate (g)+(h)+(i) | — | 4.1 (sin función) | 4.2 → gate (g); 4.5 REVOKE | 4.3 → gate (h); 4.4 → gate (i) | 4.6 COMMENT |
| 5.x | `rpc_create/update_bank_account`: existencia, P0411, P0412, soft-deactivate | SQL gate (j)+(k)+(l) | — | 5.1 (sin RPC) | 5.2 → gate (k); 5.5 → gate (l) | 5.3/5.4 → gate (j); 5.6 → gate (l) | 6.7 COMMENT |
| 6.x | `rpc_register_bank_movement`: P0410 reservado; P0401; P0412 inactiva; idempotencia | SQL gate (m)+(n)+(o) | — | 6.1 (sin RPC) | 6.2 → gate (m)/(n)/(o) | 6.3 → (m); 6.4 → (m); 6.5 → (n); 6.6 → (o) | 6.7 COMMENT |
| 7.x | Suite consolidada (SAVEPOINTs/ROLLBACK total); C1 no postea a `1110` (gate negativo) | SQL gate (p) | — | — | 7.1 DO-block final | 7.2 → gate (p) negativo 1110 | — |
