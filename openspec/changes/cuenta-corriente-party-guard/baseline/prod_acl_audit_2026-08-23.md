# Auditoría de ACLs y daño histórico en PROD — `cuenta-corriente-party-guard`

- **Proyecto**: `gxdhpxvdjjkmxhdkkwyb` (prod, usuarios reales)
- **Fecha de captura**: 2026-08-23
- **Método**: MCP `execute_sql`, SOLO `SELECT` (sin DDL/DML). Tasks 1.6, 1.7, 8.1-8.5 de `tasks.md`.
- **Gotcha #432 vigente**: prod concede `EXECUTE` a `anon`/`authenticated` directo, no vía `PUBLIC`. Todo lo de abajo se midió con `has_function_privilege(<rol>, oid, 'EXECUTE')`.

---

## 1. Task 1.6 — estado real de permisos de helpers internos

### Query

```sql
SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args, p.prosecdef,
       has_function_privilege('anon',p.oid,'EXECUTE') AS anon,
       has_function_privilege('authenticated',p.oid,'EXECUTE') AS authenticated,
       has_function_privilege('service_role',p.oid,'EXECUTE') AS service_role
FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
WHERE n.nspname='public'
  AND (p.proname LIKE '\_%' OR p.proname LIKE 'c2_%' OR p.proname LIKE 'c28\_%'
       OR p.proname LIKE 'c29\_%' OR p.proname LIKE 'c30\_%')
ORDER BY p.proname;
```

### Salida completa (22 filas)

| proname | args | secdef | anon | authenticated | service_role |
|---|---|---|---|---|---|
| `_c29_confirm_order_core` | p_idempotency_key text, p_sales_order_id uuid, p_payment_method text, p_cash_session_id uuid, p_comprobante_type text, p_point_of_sale_id uuid, p_canal text, p_payment_method_id uuid, p_bank_account_id uuid | **true** | false | **true** | true |
| `_expire_stale_subscription_intents` | | true | false | false | true |
| `_journal_post_from_event` | p_event events | **true** | false | **true** | true |
| `_journal_sale_debit_account` | p_kind text | false | false | false | true |
| `_notification_audience` | p_account_id uuid, p_target text, p_branch_id uuid | true | false | false | true |
| `_notification_from_event` | p_event events | true | false | false | true |
| `_notifications_cleanup` | | true | false | false | true |
| `_pay_register_operation_bank_movement` | p_account_id uuid, p_kind text, p_payment_method_id uuid, p_bank_account_id uuid, p_amount_abs numeric, p_direction text, p_source_doc_type text, p_source_doc_ref uuid, p_value_date date, p_branch_id uuid, p_description text | true | false | false | true |
| `_pay_register_party_charge` | p_account_id uuid, p_party_kind text, p_party_id uuid, p_amount numeric, p_reference_id uuid, p_operation_id uuid | **true** | false | **true** | true |
| `_pay_resolve_bank_account` | p_account_id uuid, p_payment_method_id uuid, p_bank_account_id_override uuid | true | false | false | true |
| `_pay_reverse_party_charge` | p_account_id uuid, p_party_kind text, p_party_account_id uuid, p_amount numeric, p_reference_id uuid, p_operation_id uuid | true | false | false | true |
| `_produce_plan_expiring_soon` | | true | false | false | true |
| `_register_bank_movement` | p_bank_account_id uuid, p_amount numeric, p_type text, p_source_doc_type text, p_source_doc_ref uuid, p_value_date date, p_branch_id uuid, p_description text | true | false | false | true |
| `_sweep_plan_limit_exceeded` | | true | false | false | true |
| `c21_apply_branch_stock_delta` | p_account_id uuid, p_product_id uuid, p_branch_id uuid, p_delta numeric | false | false | false | true |
| `c26_default_branch` | p_account_id uuid | false | false | false | true |
| `c28_register_cash_movement` | p_session_id uuid, p_amount numeric, p_type text, p_reference_id uuid, p_description text | false | false | true | true |
| `c30_get_or_create_customer_account` | p_account_id uuid, p_client_id uuid | false | **true** | true | true |
| `c30_get_or_create_supplier_account` | p_account_id uuid, p_supplier_id uuid | false | **true** | true | true |
| `c30_register_customer_account_movement` | p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid | false | **true** | true | true |
| `c30_register_supplier_account_movement` | p_account_id uuid, p_amount numeric, p_type text, p_reference_id uuid | false | **true** | true | true |

### Offenders del futuro chequeo (3) del gate ACL — `prosecdef = true AND authenticated = true`

Exactamente **3**:

| fn | args | secdef | anon | authenticated | service_role | destino según design.md |
|---|---|---|---|---|---|---|
| `_c29_confirm_order_core` | (text, uuid, text, uuid, text, uuid, text, uuid, uuid) | true | false | true | true | allowlist con comentario (OQ-3; valida `is_account_writer` sobre la orden) |
| `_journal_post_from_event` | (events) | true | false | true | true | **REVOKE** (grupo 5, task 5.4) |
| `_pay_register_party_charge` | (uuid, text, uuid, numeric, uuid, uuid) | true | false | true | true | **REVOKE** (grupo 5, task 5.3) |

**Corrección respecto de design.md D4 / tasks 6.4**: `c28_register_cash_movement` **NO es `SECURITY DEFINER` en prod** (`prosecdef=false`, authenticated=true). No cae en el chequeo (3) tal como está formulado (secdef AND authenticated) — la allowlist esperada queda con **una sola** entrada preexistente: `_c29_confirm_order_core`.

### Hallazgo lateral — `c30_*` no-secdef ejecutables por `anon`

Las cuatro `c30_*` (`get_or_create_customer_account`, `get_or_create_supplier_account`, `register_customer_account_movement`, `register_supplier_account_movement`) son `SECURITY INVOKER` con `anon=true` y `authenticated=true`. Al ser INVOKER, una llamada directa por PostgREST corre con el rol de sesión y choca contra la RLS de `customer_accounts`/`supplier_accounts` (el `INSERT` lo frena la policy, no la ACL). No son primitiva cross-tenant por sí solas, pero quedan fuera del radar de los tres chequeos del gate (ni trigger, ni secdef). La task 3.4 ya prevé `REVOKE ALL ... FROM PUBLIC, anon, authenticated` sobre las dos `get_or_create_*`; las dos `register_*_movement` quedan anotadas como candidato para el mismo tratamiento (fuera de alcance).

---

## 2. Callers de los cuatro helpers (prosrc, prod)

```sql
SELECT p.proname, p.prosecdef FROM pg_proc p
WHERE p.pronamespace='public'::regnamespace AND p.prosrc ILIKE '%<helper>(%';
```

| helper | caller | caller secdef | caller authenticated |
|---|---|---|---|
| `_journal_post_from_event` | `rpc_process_outbox_dispatch(p_batch_limit integer)` | true | false |
| `_pay_register_party_charge` | `_c29_confirm_order_core(...)` | true | true |
| `_pay_register_party_charge` | `rpc_create_sale_operation(...)` | true | true |
| `_pay_register_party_charge` | `rpc_create_sale_operation_v2(...)` | true | true |
| `c30_get_or_create_customer_account` | `_pay_register_party_charge(...)` | true | true |
| `c30_get_or_create_customer_account` | `rpc_create_customer_account(p_client_id uuid)` | true | true |
| `c30_get_or_create_customer_account` | `rpc_register_payment_received(text, uuid, numeric, uuid, text, uuid)` | true | true |
| `c30_get_or_create_supplier_account` | `_pay_register_party_charge(...)` | true | true |
| `c30_get_or_create_supplier_account` | `rpc_create_supplier_account(p_supplier_id uuid)` | true | true |
| `c30_get_or_create_supplier_account` | `rpc_register_payment_made(text, uuid, numeric, uuid, text, uuid)` | true | true |
| `c30_get_or_create_supplier_account` | `rpc_register_supplier_charge(text, uuid, numeric, uuid)` | true | true |

**Conclusión**: los 11 callers son `SECURITY DEFINER`. Ninguno corre como `authenticated` al invocar el helper → los `REVOKE ... FROM authenticated` de las tasks 3.4, 5.3 y 5.4 son transparentes para todos los callers reales. `rpc_create_purchase_operation` **no** aparece como caller de `_pay_register_party_charge` (coincide con design.md: lo cablea `compras-proveedor-cuenta-corriente`).

### Triggers

```sql
SELECT tgname, tgrelid::regclass::text, tgfoid::regproc::text FROM pg_trigger
WHERE NOT tgisinternal AND (tgfoid::regproc::text ILIKE '%journal%' OR ... '%outbox%' OR ... '%party%' OR ... '%c30%');
```

**0 filas.** Ningún trigger invoca `_journal_post_from_event`, `_pay_register_party_charge` ni los `c30_*`.

### Dispatcher del outbox — quién invoca y con qué rol

| Invocador | Qué llama | Rol efectivo | Afectado por el REVOKE de `_journal_post_from_event`? |
|---|---|---|---|
| **pg_cron job 8 `relay-process-outbox`** (`* * * * *`, `active=true`) | `SELECT public.rpc_process_outbox_dispatch(100);` | `cron.job.username = postgres` (superuser); además `rpc_process_outbox_dispatch` es `SECURITY DEFINER` → `_journal_post_from_event` corre como definer | **No** |
| Backend Python `POST /outbox/process-pending` (`backend/routers/outbox.py:32`, trigger manual/secundario) | `rpc_process_outbox_batch($1)` + `rpc_mark_event_processed($1)` (`backend/repositories/outbox_repository.py:34,47`) — **no** llama a `rpc_process_outbox_dispatch` ni a `_journal_post_from_event` | Pool `DATABASE_URL` (owner; `TENANCY_TX_SCOPE_ENABLED` apagada → sin `SET LOCAL ROLE`, solo `set_config('request.jwt.claims', ...)` — `backend/core/database.py:89-104`) | **No** (no toca el helper) |
| `supabase/functions/` | grep `outbox` → **0 archivos** | — | — |
| `frontend/` (fuera de `database.types.ts`) | solo `frontend/lib/types.ts` (tipos) | — | — |

ACLs del par en prod: `rpc_process_outbox_dispatch(integer)` secdef, anon=false, **authenticated=false**, service_role=true (ya revocada). `rpc_process_outbox_batch(integer)` secdef, anon=false, **authenticated=true**, service_role=true — es la que llama el endpoint Python vía JWT-passthrough; no llama a dispatch ni a journal (verificado con `position(...) in prosrc`). Es `rpc_*`, así que no cae en el chequeo (3) por convención de nombre.

---

## 3. Task 1.7 — consumidores de aplicación en el repo

```
grep -rn "_pay_register_party_charge\|_journal_post_from_event\|c30_get_or_create" frontend/ backend/ supabase/functions/ --include=*.ts --include=*.tsx --include=*.py
```

| ruta:línea | clasificación |
|---|---|
| `frontend/components/payment-methods/PaymentMethodSelect.tsx:113` | comentario JSDoc |
| `frontend/lib/database.types.ts:4817` (`_journal_post_from_event`) | types generados — confirma exposición por PostgREST |
| `frontend/lib/database.types.ts:4846` (`_pay_register_party_charge`) | types generados — confirma exposición por PostgREST |
| `frontend/lib/database.types.ts:4899` (`c30_get_or_create_customer_account`) | types generados |
| `frontend/lib/database.types.ts:4903` (`c30_get_or_create_supplier_account`) | types generados |
| `backend/repositories/sales_repository.py:100` | comentario SQL dentro de un docstring |
| `backend/tests/outbox/test_journal_consumer.py` (líneas 152-954, 17 hits) | tests de migración (parsean el `.sql`, no invocan la función) |

**Consumidores reales: 0.** Ningún `supabase.rpc('_pay_register_party_charge')`, ningún `conn.fetch(... _journal_post_from_event ...)`, ninguna Edge Function. El diseño D3 (REVOKE sin rediseño) se sostiene.

---

## 4. Tasks 8.1-8.5 — daño histórico (read-only)

### Volúmenes previos al join (count(*) por tabla)

| tabla | filas |
|---|---|
| clients | 1167 |
| suppliers | 0 |
| customer_accounts | 2 |
| supplier_accounts | 0 |
| payments_received | 1 |
| payments_made | 0 |
| customer_account_movements | 5 |
| supplier_account_movements | 0 |
| events | 618 |
| journal_entries | 461 |

Columnas verificadas en `information_schema.columns` antes de armar los joins: `customer_accounts(id, account_id, client_id, ...)`, `supplier_accounts(id, account_id, supplier_id, ...)`, `payments_received(id, account_id, customer_account_id, client_id, ...)`, `payments_made(id, account_id, supplier_account_id, supplier_id, ...)`, `customer_account_movements(id, customer_account_id, account_id, ...)`, `supplier_account_movements(id, supplier_account_id, account_id, ...)`, `events(id, account_id, event_type, payload jsonb, ...)`, `journal_entries(id, account_id, posted_at, source_event_id, source_doc_type, source_doc_ref, status, reversal_of, created_at)`. **`journal_entries.source_event_id` existe** → el join de (g) es real.

Claves de payload verificadas para los event_type de (f): `CustomerAccountCharged` (3 eventos) y `PaymentReceived` (1 evento) tienen `client_id` en el 100% de los casos (`account_id, amount, client_id, customer_account_id, occurred_at, operation_id, ...`). `SupplierAccountCharged` / `PaymentMade`: **0 eventos en prod**.

### Conteos

| # | medición | count |
|---|---|---|
| a | `customer_accounts ca JOIN clients c ON c.id=ca.client_id WHERE c.account_id IS DISTINCT FROM ca.account_id` | **0** |
| b | `supplier_accounts sa JOIN suppliers s ... WHERE s.account_id IS DISTINCT FROM sa.account_id` | **0** (tabla vacía) |
| c | `payments_received pr JOIN clients c ON c.id=pr.client_id WHERE c.account_id IS DISTINCT FROM pr.account_id` | **0** |
| d | `payments_made pm JOIN suppliers s ... WHERE s.account_id IS DISTINCT FROM pm.account_id` | **0** (tabla vacía) |
| e_customer | `customer_account_movements m JOIN customer_accounts ca JOIN clients c ... WHERE c.account_id IS DISTINCT FROM ca.account_id` | **0** |
| e_supplier | espejo supplier | **0** (tabla vacía) |
| f_customer | `events` con `event_type IN ('CustomerAccountCharged','PaymentReceived')` cuyo `(payload->>'client_id')::uuid` pertenece a un client con `account_id <> e.account_id` (cast protegido por regex uuid) | **0** |
| f_supplier | espejo `('SupplierAccountCharged','PaymentMade')` / `payload->>'supplier_id'` | **0** (0 eventos de esos tipos) |
| g | `journal_entries je WHERE je.source_event_id IN (<eventos de f>)` | **0** |

### Controles secundarios (mismos SELECT, para no dejar el 0 sin contraste)

| control | count | lectura |
|---|---|---|
| `customer_accounts` cuyo `client_id` no existe en `clients` (LEFT JOIN IS NULL) | 0 | no hay huérfanos que escaparan a (a) |
| `payments_received` cuyo `client_id` no existe en `clients` | 0 | ídem para (c) |
| `customer_account_movements` sin cuenta o con `m.account_id <> ca.account_id` | 0 | la columna `account_id` del movimiento es coherente con la cuenta |
| `payments_received` vs su `customer_account_id` (`account_id` o `client_id` distintos) | 0 | coherente |
| eventos (f) con `payload->>'client_id'` que no resuelve a ningún `clients.id` | 0 | (f) no tiene falsos negativos por parte inexistente |
| eventos (f) con `payload->>'account_id' <> e.account_id` | 0 | — |
| `journal_entries` con `source_event_id` que **no existe** en `events` | **0** | es el detector real de la Familia 2 (`_journal_post_from_event` recibe un composite forjado que NO se persiste en `events`; un asiento así quedaría con `source_event_id` colgado) |
| `journal_entries` con `je.account_id <> e.account_id` (vía `source_event_id`) | 0 | — |
| `journal_entries` con `source_event_id IS NULL` | **1** | `33d55c61-7026-40ed-ba11-03116e8a27ef`, `source_doc_type='SaleOperation'`, `status='reversed'`, `reversal_of=d749e9b9-ebf5-4681-b231-627f39df1410`, creado 2026-08-21 — es un contra-asiento de edición de venta (`asiento-venta-formulario`), no relacionado con cuenta corriente. Se anota, no es daño. |

**Resultado 8.6: 0 en los nueve conteos. No hay checkpoint 8.7 / OQ-5.**

---

## 5. Hallazgos inesperados

1. **`c28_register_cash_movement` no es `SECURITY DEFINER` en prod** (`prosecdef=false`). design.md D4 y tasks 6.4 lo daban por offender esperado del chequeo (3); no lo es. La allowlist inicial del gate (3) queda con **una** entrada: `_c29_confirm_order_core`.
2. **`supplier_accounts`, `suppliers`, `payments_made`, `supplier_account_movements` están vacías en prod** (0 filas) y no hay eventos `SupplierAccountCharged`/`PaymentMade`. Los conteos b/d/e_supplier/f_supplier son 0 por vacuidad, no por validación: el lado proveedor **nunca** se ejercitó en prod (coincide con el hallazgo de `compras-proveedor-cuenta-corriente`: rama `2100 Proveedores` y `P0425` nunca ejercitadas).
3. El lado cliente tampoco tiene volumen: 2 cuentas corrientes, 5 movimientos, 1 cobro, 3+1 eventos. Los "241 operaciones a crédito históricas" de `pagos-cableados-restantes` no se reflejan en `customer_accounts`/`customer_account_movements` de prod hoy — verificar si ese backfill se ejecutó o si los datos viven en otra tabla antes de citar esa cifra en el PR.
4. El endpoint Python `/outbox/process-pending` **no** es un dispatcher completo: llama `rpc_process_outbox_batch` (SELECT ... FOR UPDATE SKIP LOCKED) + `rpc_mark_event_processed`; los asientos contables los postea únicamente `rpc_process_outbox_dispatch` desde pg_cron (job 8, user `postgres`). El REVOKE de `_journal_post_from_event` no toca ese camino.
5. Las cuatro `c30_*` siguen `anon=true` (INVOKER, frenadas por RLS) — fuera del radar de los 3 chequeos del gate; candidato de endurecimiento posterior para `c30_register_*_movement`.
