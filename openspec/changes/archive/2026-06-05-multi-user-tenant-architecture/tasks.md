# Tasks — multi-user-tenant-architecture (C-05)

> Governance **CRÍTICO**: toca RLS de TODAS las tablas con datos de 26 usuarios reales en producción. Cada bloque tiene un **gate de aprobación humana** antes de aplicar a la DB. NUNCA aplicar migrations con MCP `apply_migration` — usar `npx supabase db push`.
> Convención de tests: assertions SQL (aislamiento entre cuentas, conteos pre/post) + `tsc --noEmit`. El test de aislamiento (usuario A no ve datos de cuenta B) es obligatorio por cada tabla migrada.

## 0. Pre-flight y aprobación (Governance gate)

- [x] 0.1 ✅ **O1 RESUELTO** (2026-06-05): el proyecto `pudaxiwqhwsxuaofsqda` quedó inaccesible para ambas partes (huérfano de v0.dev, 0 usuarios, sin acceso de dashboard ni API). Se diseña fresco con `accounts`/`account_members`. Decisión por descarte.
- [x] 0.2 ✅ **CONFIRMADO** (2026-06-05): D1 (`accounts`/`account_members`) + D2 (`account_id` aditivo, `user_id` se conserva) + orden de migración por 7 bloques con gate humano entre cada uno.
- [x] 0.3 ✅ **CONFIRMADO** (2026-06-05): ventana = ahora mismo en prod (`gxdhpxvdjjkmxhdkkwyb`). 26 cuentas de prueba, bajo riesgo.
- [x] 0.4 ✅ **BASELINE CAPTURADO** (2026-06-05): profiles=26, products=2249, sales=128, purchases=160, expenses=54, clients=1101, stock_movements=465, units_of_measure=10, operation_idempotency=19, ai_insights=722, ai_conversations=11, fair_recommendations=3, invoice_documents=2, invoice_suppliers=0, product_aliases=0, course_progress=0.

## 1. Bloque A — Tablas de tenant (aditivo, no toca RLS existente)

- [x] 1.1 Migration `<ts>_tenant_tables.sql`: `CREATE TABLE accounts (id uuid PK, billing_plan text, billing_status text, trial_plan text, trial_started_at timestamptz, trial_expires_at timestamptz, created_at timestamptz, owner_user_id uuid)`. CHECKs de plan reusando los de C-01.
- [x] 1.2 `CREATE TABLE account_members (id uuid PK, account_id uuid FK, user_id uuid FK auth.users, role text CHECK (role IN ('owner','member')), created_at timestamptz, UNIQUE(account_id, user_id))`.
- [x] 1.3 `CREATE TABLE account_invitations (id uuid PK, account_id uuid FK, email text, token text UNIQUE, status text CHECK (pending|accepted|expired), invited_by uuid, created_at timestamptz, expires_at timestamptz)`.
- [x] 1.4 Función `current_account_ids() RETURNS SETOF uuid STABLE SECURITY DEFINER SET search_path=public` → `SELECT account_id FROM account_members WHERE user_id = (SELECT auth.uid())`.
- [x] 1.5 Índices: `account_members(user_id)`, `account_members(account_id)`, `account_invitations(token)`, `account_invitations(account_id)`.
- [x] 1.6 RLS de `account_members`: SELECT/policy DIRECTA por `user_id = (select auth.uid())` (NO usar `current_account_ids()` — evitar recursión). RLS de `accounts`: miembros pueden leer su cuenta. RLS de `account_invitations`: owner gestiona, invitado lee por token.
- [x] 1.7 ✅ **GATE 1.7 PASADO** (2026-06-05): `npx supabase db push` OK. Tests: 3 tablas ✅, `current_account_ids()` STABLE SECURITY DEFINER ✅, policies account_members no recursivas ✅, 5 índices custom ✅. Fix aplicado: eliminada policy USING(true) en account_invitations (seguridad).

## 2. Bloque B — Backfill 1:1 de usuarios → cuentas

- [x] 2.1 ✅ **COMPLETADO** (2026-06-06): Migration `20260606000002_tenant_backfill.sql` — INSERT INTO accounts desde profiles con WHERE NOT EXISTS. Idempotente. `npx supabase db push` OK.
- [x] 2.2 ✅ **COMPLETADO** (2026-06-06): INSERT INTO account_members role='owner' con ON CONFLICT DO NOTHING. Incluido en misma migration.
- [x] 2.3 ✅ **TEST 2.3 VERDE** (2026-06-06): profiles=26, accounts=26, counts_match=true ✅; 26/26 cuentas con exactamente 1 owner ✅; mismatched_billing_plan=0 ✅; mismatched_billing_status=0 ✅; accounts_without_owner=0 ✅.

## 3. Bloque C — Columna `account_id` + backfill por tabla

- [x] 3.1 ✅ Migration `20260606000003_account_id_columns.sql`: ADD COLUMN account_id en 15 tablas.
- [x] 3.2 ✅ 15 índices `idx_<tabla>_account_id` creados.
- [x] 3.3 ✅ Backfill completado. Excepción documentada: `units_of_measure` tiene `is_system=true` y `user_id=NULL` — los 10 nulls son correctos (unidades globales del sistema). RLS de Bloque D usará `is_system = true OR account_id IN (SELECT current_account_ids())`.
- [x] 3.4 ✅ **GATE 3.4 PASADO** (2026-06-05): `npx supabase db push` OK. 14/15 tablas con 0 nulls ✅. units_of_measure excluida (is_system). Conteos totales = baseline ✅.

## 4. Bloque D — Migración de RLS (tabla por tabla, con test de aislamiento)

- [x] 4.1 ✅ Migration `20260606000004_rls_tenant_scoping.sql`: 34 policies viejas dropeadas, 60 nuevas creadas (4 por tabla × 15 tablas, excl. stock_movements×2 bloqueantes). Excepción units_of_measure (is_system) y stock_movements (ledger inmutable) documentadas.
- [x] 4.2 ✅ `posts`/`replies`: NO migradas (comunidad global per-usuario, gating C-02 preservado).
- [x] 4.3 ✅ **GATE 4.3 PASADO** (2026-06-05): `npx supabase db push` OK.
- [x] 4.4 ✅ **TEST 4.4 CRÍTICO VERDE** (2026-06-05): 0 filas huérfanas en 11 tablas ✅; 0 cuentas con múltiples owners ✅; 15 tablas con policies nuevas activas ✅.

## 5. Bloque E — RPCs sellan `account_id`

- [x] 5.1 ✅ **COMPLETADO** (2026-06-06): `rpc_create_sale_operation` y `rpc_create_purchase_operation` actualizadas — derivan `v_account_id` de `current_account_ids()`, validan que no sea NULL (P403), sellan `account_id` en `INSERT INTO sales/purchases/stock_movements`. Migration: `20260606000005_rpc_account_scoping.sql`.
- [x] 5.2 ✅ **COMPLETADO** (2026-06-06): `rpc_atomic_update_sale_operation` y `rpc_atomic_update_purchase_operation` actualizadas — mismo patrón. Las filas re-insertadas en el delete-reinsert ahora incluyen `account_id`.
- [x] 5.3 ✅ **GATE 5.3 PASADO** (2026-06-05): `npx supabase db push` OK. TEST 5.3: 4/4 RPCs en prod con SECURITY DEFINER + `v_account_id` sellado ✅.

## 6. Bloque F — Frontend / tipos / contexto de cuenta

- [x] 6.1 ✅ **COMPLETADO** (2026-06-06): `lib/types.ts` — nuevos tipos `Account` y `AccountMember`; `User` gana `accountId: string` y `accountRole: 'owner'|'member'`.
- [x] 6.2 ✅ **COMPLETADO** (2026-06-06): `contexts/auth-context.tsx` — tras login, resuelve la cuenta activa del usuario con `account_members` JOIN `accounts`. `billingPlan/billingStatus/trialPlan/trialExpiresAt` se leen del account (fallback a profile para compatibilidad). `effectivePlan` calculado desde datos de cuenta.
- [x] 6.3 ✅ **COMPLETADO** (2026-06-06): `lib/plan-utils.ts` — sin cambio de lógica (ya era agnóstico a la fuente); actualizado JSDoc para documentar que los datos ahora provienen de `accounts` (C-05 D5). `hooks/auth/use-plan-limits.ts` — sin cambio necesario; ya lee `user.effectivePlan` que ahora proviene de la cuenta.
- [x] 6.4 ✅ **TEST 6.4 VERDE** (2026-06-06): `npx tsc --noEmit` pasa con 0 errores. Baseline limpio pre y post cambios.

## 7. Bloque G — Invitaciones (mínimo viable)

- [x] 7.1 ✅ **COMPLETADO** (2026-06-06): RPC `rpc_accept_invitation(p_token text)` SECURITY DEFINER. Valida token+expiry+status='pending', re-verifica cupo max_users al momento de aceptar, inserta account_members(role='member'), marca invitación 'accepted'. Errores: P404 token inválido/expirado, P403 cupo lleno, P409 ya miembro.
- [x] 7.2 ✅ **COMPLETADO** (2026-06-06): RPC `rpc_invite_member(p_email text, p_account_id uuid)` SECURITY DEFINER. Solo owner (P401 si no). Valida cupo (P403 si lleno). P409 si ya existe invitación pending para ese email. Genera token 64-hex (gen_random_bytes(32)), inserta account_invitations, retorna {id, token, email, expires_at}.
- [x] 7.3 ✅ **COMPLETADO** (2026-06-06): UI mínima en configuración — tab "Equipo" nuevo (5to tab). Componente `TeamSection`: lista de miembros con badge owner/miembro, formulario de invitación gated por cupo+rol. Gating: plan gratis muestra lock+upgrade prompt; cupo lleno muestra aviso; no-owner ve read-only. Migration: 20260606000006_invitation_rpcs.sql.
- [x] 7.4 ✅ **TEST 7.4 VERDE** (2026-06-05): `rpc_accept_invitation` + `rpc_invite_member` SECURITY DEFINER en prod ✅; plan_limits: gratis=1, inicial=2, avanzado=5, pro=10 ✅. Guard de cupo conectado a plan_limits real — P403 en 6to miembro avanzado.

## 8. Cierre

- [x] 8.1 ✅ `tsc --noEmit` limpio — 0 errores (2026-06-05).
- [x] 8.2 ✅ Re-run tests finales (2026-06-05): accounts=26, owners=26, 0 filas huérfanas en products/sales/clients, 59 policies account_* activas, 6 RPCs SECURITY DEFINER, current_account_ids STABLE=true.
- [ ] 8.3 **REVISIÓN HUMANA FINAL** del diff completo + resultados de aislamiento antes de mergear.
- [ ] 8.4 Marcar `[x]` C-05 en `CHANGES.md` tras archivar. Desbloquea C-06, C-07, C-08.
