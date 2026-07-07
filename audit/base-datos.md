# Auditoría técnica pre-producción — Dimensión: Base de Datos (PostgreSQL/Supabase)

**Proyecto**: ALIADATA / EmprendeSmart (EIE) · **Proyecto Supabase PROD**: `gxdhpxvdjjkmxhdkkwyb`
**Fecha de auditoría**: 2026-07-07 · **Auditor**: Database Architect (consultora externa)
**Método**: lectura del repo (204 migraciones en `supabase/migrations/`, `knowledge-base/04_modelo_de_datos.md`, `scripts/smoke_c29_quote_salesorder.sql`) + verificación en vivo contra prod vía MCP en modo estrictamente read-only (SELECT + advisors + metadata). Cero escrituras sobre la DB.

**Clasificación final: MUY BUENA** — fundamentos sólidos (RLS 100%, PKs 100%, historial de migraciones perfectamente sincronizado, ledgers serializados correctamente, idempotencia real), con un hallazgo de seguridad concreto (RPCs admin ejecutables por `anon`) y deuda de consistencia en líneas de documento que impiden el "Excelente".

---

## 1. Estado real de prod (verificado por SQL)

| Métrica | Valor |
|---|---|
| Tablas `public` | 68 |
| Tablas `community` | 16 |
| Tablas sin PK (public+community) | **0** |
| Tablas con RLS deshabilitada (public+community) | **0** |
| Tablas con RLS y sin policy | 1 (`platform_wsaa_tickets` — deny-all para anon/authenticated; solo service_role la usa; por diseño) |
| Migraciones aplicadas | 204 — `20250101000001` → `20260815000001` |
| Sync repo↔prod | **PERFECTO**: md5 del listado de versiones local == prod (`9df1d9563780c13742d23f38e879df07`) |
| Índices en `public` | 274 |
| accounts / profiles | 29 / 29 |
| sales / sale_items | 279 / 293 |
| purchases / purchase_items | 287 / 244 |
| stock_movements / branch_stock | ~874 / ~1.860 |
| events (outbox) | 46 total, **0 pendientes** (sano) |
| journal_entries / journal_lines | 8 / 16 |
| document_status_history | **0 filas** |
| document_status_transitions (catálogo FSM) | 18 |
| operation_idempotency | 204 filas, 3 operation_kinds |
| quotes / sales_orders / fiscal_documents / cash_sessions | 0 / 2 / 1 / 1 |
| Tabla más grande | email_logs 3,8 MB (~4.849 filas) — escala doméstica, sin presión |

**Integridad referencial (spot checks, todos = 0 huérfanos)**: sale_items→sales, sales→accounts, stock_movements→products, branch_stock→branches, journal_lines→journal_entries. Sin ventas con montos negativos; `sale_items.quantity` NOT NULL y sin valores ≤ 0.

---

## 2. Hallazgo principal de seguridad — RPCs SECURITY DEFINER ejecutables por `anon` sin guard

**Evidencia (verificada función por función en `pg_proc` + advisors):**

Las 5 funciones `get_admin_*` son `SECURITY DEFINER`, **sin** `IF is_admin()` interno, **sin** `SET search_path`, y con `EXECUTE` otorgado a `anon` y `authenticated` → invocables por cualquiera con la anon key (pública, embebida en el frontend) vía `POST /rest/v1/rpc/<fn>`:

| Función | Guard admin | search_path fijo | Expone |
|---|---|---|---|
| `get_admin_paid_conversion_rate()` | ✗ | ✗ | % conversión free→pro de la plataforma (leído de `profiles`) |
| `get_admin_activation_rate(...)` | ✗ | ✗ | tasa de activación |
| `get_admin_umv_rate(...)` | ✗ | ✗ | tasa UMV |
| `get_admin_insights_breakdown(...)` | ✗ | ✗ | breakdown de insights IA |
| `get_admin_community_interactions(...)` | ✗ | ✗ | actividad de comunidad |

Contraste: la generación nueva de RPCs admin (`rpc_admin_business_kpis`, `rpc_admin_kpi_overview`, `rpc_admin_module_stats`, `rpc_admin_retention_30d`, `rpc_admin_weekly_usage_distribution`) **sí** tiene `IF NOT public.is_admin(auth.uid()) THEN RAISE` + `SET search_path TO 'public'` (verificado en la definición en prod). El problema es solo la camada legacy.

Además, el advisor reporta **57 funciones SECURITY DEFINER ejecutables por `anon`** (94 por `authenticated`). La mayoría son inofensivas (trigger functions no invocables por REST, o funciones con `auth.uid()` que devuelven vacío sin JWT), pero entre las invocables hay funciones de mantenimiento con efectos: `expire_trials()`, `process_cancellations()`, `queue_trial_notifications()`, `check_low_margin()` — un caller anónimo puede dispararlas a voluntad (vector de abuso/side-effects, p.ej. encolar notificaciones).

**Remediación (barata, sin downtime)**: `REVOKE EXECUTE ... FROM anon, authenticated` + `GRANT` selectivo, sumar guard `is_admin()` y `SET search_path = ''` a las 5 legacy; auditar la lista completa de 57 con un criterio deny-by-default (el proyecto ya tiene el patrón: `20260616000005_v20_advisor_fixes.sql`, `20260808000003_v3_notifications_advisor_revoke.sql`).

**Nota search_path**: solo 5 funciones SECURITY DEFINER de ~150 carecen de `search_path` fijado (las mismas 5 admin legacy). El resto del inventario está correcto — muy por encima del promedio. Otras 3 funciones no-DEFINER con search_path mutable (`custom_access_token_hook`, `reporting_local_today`, `rpc_set_primary_client_address`) son de riesgo menor (invoker o invocadas por el auth server).

---

## 3. Consistencia de líneas de documento (sale_items / purchase_items)

### 3.1 Compras: `purchase_items` quedó congelada a mitad de historia (K8 confirmado)

- `rpc_create_purchase_operation` (write path que llama el backend, `backend/repositories/purchase_repository.py:235`) **no escribe `purchase_items` ni despacha a v2** (verificado en prod: `writes_items=false`, `reads_flag=false`).
- Esto es **intencional y documentado** — decisión D2 de `20260806000001_v3_snapshot_pattern.sql:112-123`: "el write path de compra escribe purchases (flat), no purchase_items... purchase_items NO es el write path vigente" (los snapshots de compra viven en el header `purchases`).
- **Pero el resultado en datos es una tabla mixta**: compras sin líneas por mes → mar 0/6, abr 0/15, may 3/111, jun 21/118, **jul 37/37**. `purchase_items` tiene 244 filas históricas (18 con `account_id` NULL) y ya no recibe escrituras.
- Riesgo: cualquier consumidor (reporte, export, IA) que lea `purchase_items` como fuente de líneas de compra subrepresenta la realidad sin error visible. Recomendación: o backfill+reactivación (cuando C-20 Grupo 10 retome) o marcar la tabla con COMMENT de deprecación dura y lint en el backend.

### 3.2 Ventas: snapshots incompletos

- Flag `sale_items_rpc_v2` habilitado en **26/29 cuentas** (verificado en `account_feature_flags`); las 3 restantes generan ventas sin `sale_items` (3 ventas desde 2026-07-02 sin líneas). El despacho por flag vive dentro de `rpc_create_sale_operation` (correcto, transparente para el backend).
- `iva_rate_snapshot` NULL en **293/293** sale_items (K12 confirmado — products no tiene columna IVA).
- `name_snapshot` NULL en **50/293** sale_items: el backfill 4.1 de `20260806000001` no cubrió filas cuyo producto ya no existía o variantes legacy. Las líneas nuevas v2 sí lo escriben.
- Consecuencia: el objetivo V3 "línea inmutable como única fuente" todavía no es invariante de datos; sigue dependiendo del header (RN-97), lo cual el sistema maneja correcto hoy (los RPCs de reporting leen headers con `COALESCE(total, amount)` — verificado en `get_dashboard_financials`), pero la ventana de inconsistencia existe mientras convivan ambos modelos.

---

## 4. FSM / document_status_history: catálogo listo, enforcement solo en RPCs

- Catálogo `document_status_transitions`: 18 transiciones. Helpers cableados en **11 funciones** (verificado: `rpc_accept_quote`, `rpc_quick_sale`, `_c29_confirm_order_core`, `rpc_open/close_cash_session`, `rpc_open/close_reconciliation_session`, `rpc_emit_pending_cae`, `rpc_record_fiscal_transition`, `rpc_transfer_stock`, `trg_quote_record_creation`).
- **`document_status_history` = 0 filas en prod.** Consistente con el uso real (quotes=0, sales_orders=2 previas al ship, cash_sessions=1, quick_sale jamás ejecutado: 0 filas en operation_idempotency con ese kind) — la maquinaria FSM está **completamente sin ejercitar en producción**.
- **Gap de enforcement (K15 confirmado y ampliado)**: la policy `quotes_update` permite `UPDATE` directo de `status` a cualquier writer (`is_account_writer`), sin validación de transición y sin escribir historial; **no existe trigger BEFORE UPDATE** en quotes/sales_orders/fiscal_documents que valide contra el catálogo. El único trigger de quotes es `quotes_record_status_creation` (INSERT). `allowed_role` es inerte (RBAC singular: CHECK `role IN ('owner','admin','member')` verificado en `account_members`).
- Recomendación: trigger BEFORE UPDATE OF status que valide la transición contra el catálogo y registre historial (o al menos bloquee cambios de status por UPDATE directo, forzando el paso por RPC). Esto convertiría la FSM-como-datos en invariante real.

---

## 5. RLS — cobertura y calidad

**Cobertura: 100% de las 84 tablas con RLS habilitada.** Única tabla sin policy: `platform_wsaa_tickets` (deny-all efectivo; solo service_role — correcto para tickets WSAA de plataforma; el GRANT SELECT a anon/authenticated es inocuo con RLS sin policy, pero convendría revocarlo por higiene).

**K1 confirmado** — ledgers financieros con RLS solo-lectura (deny-by-default para escritura, escriben RPCs SECURITY DEFINER):
- `bank_accounts`: solo `bank_accounts_select`
- `bank_movements`: solo `bank_movements_select`
- `cash_movements`: solo `cash_movements_select`
- `cash_sessions`: solo `cash_sessions_select`
- `cashboxes`: `cashboxes_select` + `cashboxes_insert`
Esto es una **fortaleza** (append-only forzado a nivel policy), con el TODO conocido: exponer edición/baja en UI requerirá policy o RPC dedicada.

**Deuda de calidad (advisors, deduplicado):**
- `multiple_permissive_policies` (67 warnings): pares OR-permisivos en `profiles` (admin+own para SELECT/UPDATE), `suppliers` (legacy "Users can access their suppliers" company-based con cmd ALL + 4 policies account-based), `billing_events`, `plan_limits`, `account_members`, y 8 tablas de `community` evaluando policies de admin para `anon`/`authenticator`/`cli_login_postgres`. Costo de evaluación + superficie de razonamiento.
- `auth_rls_initplan` (8 policies): `product_attributes` (4), `export_logs` (3), `wsaa_access_tickets` (1) re-evalúan `auth.uid()` por fila en vez de `(select auth.uid())`. `product_attributes` es la única con proyección de crecimiento real (catálogo de 3.684 productos).

**Caso `suppliers` (residuo de tenancy)**: la policy legacy `"Users can access their suppliers"` (ALL) autoriza por `company_id IN (SELECT ... FROM company_users ...)` y convive en OR con las policies account-based. `company_users` aún tiene **5 filas** vivas. Hoy es inofensivo (suppliers = **0 filas** en prod), pero es exactamente el tipo de dualidad que produce bypass silencioso si la tabla se puebla: un usuario removido de `account_members` pero presente en `company_users` retendría acceso. Dropear la policy legacy es gratis.

---

## 6. Residuos de tenancy legacy (post C-19)

- **10 tablas** conservan columna `company_id`; `user_id` sigue vivo en las 5 tablas calientes (`sales`, `purchases`, `products`, `clients`, `expenses`).
- `company_users`: 5 filas; `companies`: vivas.
- Índices legacy activos sobre columnas muertas: `idx_sales_user`, `idx_sales_user_date`, `idx_sales_company`, `idx_products_company`, `idx_clients_company`, `idx_purchases_company/user`, `idx_expenses_company/user` — todos en la lista de "unused" del advisor.
- Es consistente con RN-97/C-20 Grupo 10 diferido, pero el DROP de policies+índices legacy no depende del drop de columnas y podría adelantarse.

---

## 7. Índices

**Hot paths bien cubiertos** (verificado): `sales` (account_id, account+canal, operation_id, client_id, account+branch), `sale_items` (sale_id, product_id, account_id, unique sale+product), `branch_stock` (unique product+branch, account+branch), `stock_movements` (account, product, reference, op_group, transfer), `events` con índice parcial `events_unprocessed_idx` (ideal para el consumer del outbox), `notifications` (account+created, account+unread parcial), `cash_movements` (session+created_at). Los índices únicos parciales de soft-delete RN-B3 existen en prod (`idx_products_sku_user`, `idx_products_barcode_unique`, `cost_centers_account_name_lower_idx`, `idx_client_addresses_primary` con `WHERE is_primary AND deleted_at IS NULL`).

**48 FKs sin índice de cobertura** (advisor, deduplicado por tabla): `payments_received` (client, customer_account, movement, created_by), `payments_made` (4), `quotes`/`quote_items`/`sales_orders`/`sales_order_items` (12), `fiscal_documents` (client, fiscal_profile, point_of_sale), `sales.branch_id`, `purchases.branch_id/cost_center_id`, `stock_movements.branch_id`, `expenses.branch_id/cost_center_id`, `bank_movements.branch_id`, `journal_entries.reversal_of`, `journal_lines.cost_center_id`, `customer/supplier_accounts.*`, `cash_sessions.opened_by/closed_by`. Con el volumen actual (<5k filas máx.) el impacto es nulo; el costo aparece con crecimiento (joins de reporting por branch y cascadas/validaciones de DELETE en padres). Priorizar: `sales.branch_id`, `stock_movements.branch_id`, `payments_*` y las tablas de documentos.

**55 índices sin uso** (advisor): mezcla de (a) legacy tenancy (candidatos a DROP inmediato), (b) tablas nuevas aún sin tráfico (bank_*, reconciliation_*, journal_* — esperables, conservar), (c) redundancias reales (`idx_sales_unit`, `idx_purchases_unit`, `idx_uom_base_unit`). `sales` acumula 12 índices para 279 filas — write amplification en la tabla más caliente.

---

## 8. RPCs del hot path y ledgers — calidad transaccional

- **K17 RESUELTO** (verificado en prod): `c28_register_cash_movement` calcula `balance_after = opening_balance + SUM(movimientos)` bajo `SELECT ... FOR UPDATE` de la sesión, con comentario explícito de por qué NO usar MAX (fix `20260804000003`). Mismo patrón que `_register_bank_movement`.
- CHECKs de dominio correctos en ledgers: `movement_type` enumerado en cash/bank/customer/supplier movements; `balance_after >= 0` en ctas ctes; `branch_stock.quantity >= 0`.
- Idempotencia: `operation_idempotency` con 204 filas / 3 kinds activos; el patrón ON CONFLICT + retorno de operación previa está en todos los RPCs de creación. La lección C3 (enumerar la unión vigente del CHECK de `operation_kind` antes de recrearlo) sigue vigente como regla operativa.
- Outbox: 46 eventos, 0 pendientes, 0 stuck — consumers al día.
- `rpc_atomic_update_purchase_operation` no escribe purchase_items (coherente con D2).
- Sin CHECK `quantity > 0` en `sale_items`/`purchase_items` (la validación vive en el RPC); los datos actuales están limpios (0 filas con qty ≤ 0). Mejora barata si se quiere blindar contra escrituras futuras fuera de RPC.

---

## 9. Journal (partida doble) — ledger incompleto por diseño temporal

`journal_entries` = 8, `journal_lines` = 16, contra ~550 documentos históricos (ventas+compras). El outbox→JournalEntry revivió el 2026-07-01 sin backfill histórico: el journal solo cubre operaciones posteriores. No es un bug (los RPCs de reporting leen headers con invariantes RN-D correctas — verificado `COALESCE(total, amount)` en `get_dashboard_financials`), pero **el journal no es usable como fuente contable histórica** y conviene documentarlo explícitamente para que nadie construya reportes sobre él sin backfill.

---

## 10. Higiene de migraciones (204)

- **Sincronización repo↔prod perfecta**: 204 versiones idénticas (md5 igual), sin drift, sin huecos, sin duplicados de timestamp local.
- Convención de naming clara (`<ts>_<change>_<detalle>.sql`), migraciones con comentarios de decisión (D1/D2/D3 en el snapshot pattern) — calidad narrativa muy por encima del promedio.
- Patrón maduro: cleanup intercalado para gates de CI (`20260804000008`, `20260806000002`), idempotencia de migraciones (lección de la integración GitHub de Supabase que auto-aplica), NOT VALID + VALIDATE para FKs sobre datos vivos (`20260810000001`).
- **K2 confirmado como deuda latente**: gates de comportamiento con bugs dentro de migraciones ya aplicadas — `v_profit_row RECORD` (`20260806000001:2034`, uso en :2366-2374) y gates d-k de `20260804000007` (24 bloques degradan con NOTICE, no abortan). No afectan prod (son gates), pero el gate puede dar falso verde en esas secciones en cada `db reset` de CI.
- Volumen: 204 migraciones para 18 meses de vida es alto pero manejable; no hay squash. Riesgo: el `db reset` de CI ya corre toda la historia (costo creciente de pipeline). Considerar squash de la era pre-V2 cuando el equipo lo tolere.

---

## 11. Modelo real vs `knowledge-base/04_modelo_de_datos.md`

La KB está honestamente marcada como "modelo en transición / parcial", pero quedó atrás:
- Dice "la DB real tiene **55 tablas**" → hoy son **68 en `public` + 16 en `community`**.
- H1 afirma "`suppliers` solo tiene `company_id` — hueco de tenancy" → ya tiene `account_id` + 4 policies account-based (el hueco se cerró; la policy legacy quedó).
- H8 describe `events` outbox "0 filas, sin wiring" → hoy activo con 4 consumers.
- No documenta ~20 tablas nuevas de V2.5/V3: `bank_accounts/movements`, `bank_statement_imports/lines`, `reconciliation_sessions/matches`, `journal_entries/lines`, `notifications`, `document_status_history/transitions`, `client_addresses`, `cost_centers`, `quotes/quote_items`, `sales_orders/items`, `cash_sessions/movements/cashboxes`, `customer/supplier_accounts(+movements)`, `fiscal_documents/profiles`, `points_of_sale`, `document_sequences`, `wsaa_access_tickets`, `platform_wsaa_tickets`, `account_feature_flags`.
- Las convenciones (UUID, NUMERIC(15,2)/(15,4), created_at) sí se cumplen en las tablas nuevas (verificado por muestreo).

---

## 12. Escalabilidad

Volumen actual minúsculo (tabla más grande: 3,8 MB). Nada urge. De cara al objetivo comercial:
- Ledgers append-only (`stock_movements`, `cash_movements`, `bank_movements`, `*_account_movements`, `document_status_history`, `audit_logs`, `events`) crecen linealmente con operación; el diseño con `balance_after` + índices compuestos aguanta sin particionado por años a esta escala. Umbral de revisión razonable: >5-10M filas/tabla.
- `email_logs` y `analytics_events` son los primeros candidatos a retención/purga programada (ya existe el precedente `20260630000001_purge_cron_job_run_details`).
- El costo real de escala hoy es el **CI db reset** (204 migraciones + gates), no prod.
- pgBouncer transaction mode (K10) es compatible con el patrón actual (JWT-passthrough vía claims por statement, sin SET ROLE persistente).

---

## 13. Verificación de known issues (área DB)

| ID | Estado | Nota |
|---|---|---|
| K1 | **CONFIRMADO** | bank_accounts/bank_movements/cash_movements/cash_sessions: solo SELECT; cashboxes: SELECT+INSERT. Escritura solo vía RPC (deny-by-default, correcto); falta policy/RPC para update/delete cuando la UI lo exponga. |
| K2 | **CONFIRMADO** | `v_profit_row RECORD` en `20260806000001:2034` (uso :2366-2374); 24 bloques NOTICE en `20260804000007`. Latente en migraciones aplicadas; solo afecta la fiabilidad del gate en CI. |
| K3 | **CONFIRMADO** | 23 sale_items + 18 purchase_items con `account_id` NULL (verificado por COUNT en prod). Coherente con la ausencia de NOT NULL. |
| K4 | **CONFIRMADO (mejorado)** | Flag `sale_items_rpc_v2` habilitado en 26/29 cuentas; 3 siguen off → 3 ventas desde 07-02 sin sale_items. |
| K5 | **NO_EVALUADO** | Es de backend/Render; desde la DB: RPC de compras sano, 37 compras de julio insertadas OK (el 500 no deja rastro en DB). |
| K7 | **CONFIRMADO** | `products.min_stock` sigue existiendo (INTEGER), comentada como DEPRECATED; fuente real `branch_stock.min_stock`. |
| K8 | **CONFIRMADO** | `rpc_create_purchase_operation` no escribe purchase_items ni despacha a v2 (verificado en prod); D2 de `20260806000001` lo declara write path flat vigente. 37/37 compras julio sin líneas. |
| K9 | **CONFIRMADO** | CHECK `role IN ('owner','admin','member')` en account_members; `allowed_role` FSM inerte. |
| K11 | **CONFIRMADO** | Types reales en uso: `length,unit,volume,weight` (10 UoM, todas globales account_id NULL) ≠ canónico V3. |
| K12 | **CONFIRMADO** | `iva_rate_snapshot` NULL en 293/293 sale_items. |
| K15 | **CONFIRMADO (ampliado)** | Sin trigger BEFORE UPDATE en quotes/sales_orders/fiscal_documents; `quotes_update` permite cambiar status por UPDATE directo sin historial. `document_status_history`=0. |
| K17 | **RESUELTO** | `c28_register_cash_movement` usa `opening_balance + SUM` bajo FOR UPDATE (verificado definición en prod). |
| K18 | **CONFIRMADO** | `audit_logs.company_id` y `entity_type` nullable (is_nullable=YES). |
| K19 | **NO_EVALUADO** | Preview fuera de scope por instrucción (read-only sobre prod únicamente). |

---

## 14. Advisors (deduplicados)

**Security (163 lints → 6 clases):**
1. `anon_security_definer_function_executable` × 57 / `authenticated_...` × 94 → ver §2 (el hallazgo real son las 5 admin legacy sin guard + funciones de mantenimiento invocables).
2. `function_search_path_mutable` × 8: las 5 admin legacy (SECURITY DEFINER) + `custom_access_token_hook`, `reporting_local_today`, `rpc_set_primary_client_address` (invoker, riesgo menor).
3. `rls_enabled_no_policy` × 1: `platform_wsaa_tickets` (por diseño; revocar GRANTs a anon/authenticated por higiene).
4. `public_bucket_allows_listing` × 2: buckets `avatars` y `landing` con SELECT amplio en storage.objects → listado de todos los archivos.
5. `auth_leaked_password_protection` × 1: deshabilitada (config de Auth, activar).

**Performance (178 lints → 4 clases):**
1. `unindexed_foreign_keys` × 48 → §7.
2. `unused_index` × 55 → §7.
3. `multiple_permissive_policies` × 67 → §5.
4. `auth_rls_initplan` × 8 → §5.

---

## 15. Fortalezas (con evidencia)

1. **RLS al 100% y PK al 100%** en las 84 tablas de public+community (query directa a pg_class/pg_constraint: 0 y 0).
2. **Historial de migraciones impecable**: 204/204 sincronizadas repo↔prod, md5 idéntico; naming, comentarios de decisión y patrón NOT VALID+VALIDATE.
3. **Ledgers financieros serializados correctamente**: FOR UPDATE + opening+SUM (no MAX), balance_after persistido, CHECKs de dominio, RLS solo-SELECT (append-only forzado).
4. **Outbox sano en prod**: 0 eventos pendientes, índice parcial para el consumer, idempotencia por operation_idempotency.
5. **Integridad de datos verificada**: 0 huérfanos en todos los spot checks; 0 cantidades inválidas; snapshots nuevos escribiéndose.
6. **search_path fijado en ~97% de las SECURITY DEFINER** (solo 5 legacy sin fijar) — inusualmente bueno.
7. **Soft-delete RN-B3 real**: índices únicos parciales `WHERE deleted_at IS NULL` en prod, guard trigger en products.
8. **Invariantes de reporting RN-D aplicadas** (`COALESCE(total,amount)` verificado en get_dashboard_financials; los RPCs admin nuevos con guard+search_path).
9. **Smoke transaccional de prod** (`scripts/smoke_c29_quote_salesorder.sql`): patrón DO + subtransacciones + RAISE final para rollback garantizado, inyección de JWT claims para simular authenticated — ejemplar.

## 16. Recomendaciones priorizadas

| # | Acción | Prioridad | Esfuerzo |
|---|---|---|---|
| 1 | REVOKE anon/authenticated + guard is_admin() + search_path en las 5 `get_admin_*`; auditar los 57 EXECUTE de anon (deny-by-default) | P0 | Horas |
| 2 | Decidir destino de `purchase_items` (backfill+reactivar vs deprecar duro) y activar flag v2 en las 3 cuentas restantes (decisión PO ya pendiente) | P1 | Días |
| 3 | Trigger BEFORE UPDATE OF status validando contra `document_status_transitions` + registro de historial (o bloquear UPDATE directo de status) | P1 | 1 día |
| 4 | DROP de policies/índices legacy de tenancy (suppliers "Users can access...", idx_*_user/company) — no requiere drop de columnas | P2 | Horas |
| 5 | Índices en FKs de hot paths futuros (sales.branch_id, stock_movements.branch_id, payments_*, quotes/sales_orders) | P2 | Horas |
| 6 | Fix auth_rls_initplan (4 tablas) y consolidar policies permisivas duplicadas | P2 | Horas |
| 7 | Actualizar KB 04 (conteo real de tablas, H1 obsoleto, tablas V2.5/V3) | P2 | Horas |
| 8 | Documentar que el journal no tiene backfill histórico; plan de backfill si se usará contablemente | P3 | — |
| 9 | Activar leaked password protection; revisar policies de listado en buckets públicos | P3 | Minutos |
| 10 | Plan de retención para email_logs/analytics_events; evaluar squash de migraciones pre-V2 para CI | P3 | — |
