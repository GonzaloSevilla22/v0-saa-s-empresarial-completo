> **Strict TDD**: los gates SQL de comportamiento (grupo 3) son el RED de este change. Escribirlos **antes** de crear los triggers, verificar que fallan contra la base sin la migración, y recién después aplicar el grupo 2. Cada gate corre con `psql -v ON_ERROR_STOP=1`.
>
> **Sin superficie frontend**: change de infraestructura de telemetría. Los paneles admin que la consumen ya existen (`/admin`, `frontend/lib/adminAnalytics.ts`) y no cambian de contrato. Declarado por la regla PO 2026-08-02.
>
> **Grupo 6 (backfill) está BLOQUEADO por el sign-off de OQ-2.** Los grupos 1-5 y 7 son ejecutables ya.

## 1. Verificación previa del estado real

- [x] 1.1 Confirmar contra la base de producción (MCP `execute_sql`, sólo lectura) el schema vigente de `analytics_events`: columnas, nullability e índices existentes; contrastar con `20250101000003_create_tables.sql:102-121` y `20260227000100`/`20260228000100` — **confirmado 2026-08-12**: schema idéntico al documentado (`id`, `user_id` nullable, `event_name` NOT NULL, `event_data` jsonb, `created_at`), 7 índices existentes coinciden exactamente con el design.
- [x] 1.2 Contar duplicados históricos de `first_operation` por `user_id` en producción (`GROUP BY user_id HAVING COUNT(*) > 1`) — determina si el paso de limpieza previa al índice único es no-op o real — **NO es no-op**: 7 usuarios con duplicados en prod (máximo 21 filas para uno solo), confirma la precondición D4 del design. La limpieza de la migración es real, no defensiva.
- [x] 1.3 Verificar que `sales`, `purchases` y `expenses` tienen `user_id NOT NULL` y `account_id` en producción, y medir cuántas filas tienen `account_id` NULL (afecta la calidad del `account_id` del evento) — **confirmado**: `user_id` NOT NULL en las 3 tablas; `account_id` nullable pero **0 filas NULL** en las 3 (581 sales, 366 purchases, 139 expenses) — el `account_id` del evento estará poblado para toda operación existente.
- [x] 1.4 Confirmar que `analytics_events` **no** tiene `FORCE ROW LEVEL SECURITY` (si lo tuviera, el `SECURITY DEFINER` no bastaría para escribir y habría que ajustar el emisor) — **confirmado**: `relrowsecurity=true, relforcerowsecurity=false`. El `SECURITY DEFINER` bypasea la RLS de INSERT sin necesitar ajustes.
- [x] 1.5 Verificar que ninguna migración posterior a las auditadas redefine `rpc_create_insight` ni las RPCs legacy que emiten telemetría, y anotar la lista final de emisores existentes — **hallazgo**: `rpc_create_insight` **ya no existe** en prod — fue reemplazada por `rpc_atomic_log_ai_insight(p_type, p_content, p_source_function)`, que conserva **exactamente la misma lógica** de detección de UMV (`EXISTS(operation_created) AND NOT EXISTS(umv_reached)`). El requirement modificado de la capability `insights` referencia `rpc_create_insight` por nombre — desactualizado en el texto, pero la garantía funcional (D9: la UMV depende del choke point) sigue siendo correcta bajo el nombre nuevo; no se re-litiga el design (instrucción del apply), se deja anotado para que `openspec-sync-specs`/una revisión posterior actualice el nombre en el spec. `rpc_create_sale_operation(_v2)` / `rpc_create_purchase_operation(_v2)` confirmadas SIN emisión (0 referencias a `analytics_events`); no existen triggers previos en sales/purchases/expenses.

## 2. Migración de emisión — `supabase/migrations/20260914000001_analytics_events_revival.sql`

> Timestamp posterior a `20260913000001_critical_stock_by_branch.sql`. Idempotente y both-worlds-safe: la integración GitHub de Supabase auto-aplica al mergear ANTES del `db push` de Actions, así que la migración puede correr más de una vez.

- [x] 2.1 Cabecera del archivo con el bloque estándar del proyecto: QUÉ HACE, gobernanza (MEDIO), idempotencia, APPLY (vía CI, nunca MCP `apply_migration`) y ROLLBACK
- [x] 2.2 `ALTER TABLE public.analytics_events ADD COLUMN IF NOT EXISTS account_id uuid REFERENCES public.accounts(id) ON DELETE CASCADE`
- [x] 2.3 `CREATE INDEX IF NOT EXISTS` sobre `analytics_events (account_id, created_at)`
- [x] 2.4 Limpieza idempotente de `first_operation` duplicados: conservar el `created_at` más antiguo por `user_id`, borrar el resto. Debe ir **antes** del índice único del paso 2.5 y en la misma transacción
- [x] 2.5 `CREATE UNIQUE INDEX IF NOT EXISTS ux_analytics_first_operation_user ON public.analytics_events (user_id) WHERE event_name = 'first_operation'`
- [x] 2.6 `CREATE UNIQUE INDEX IF NOT EXISTS ux_analytics_operation_entity ON public.analytics_events (event_name, (event_data->>'entity_id')) WHERE event_name = 'operation_created' AND event_data ? 'entity_id'`
- [x] 2.7 `CREATE OR REPLACE FUNCTION public.analytics_emit_operation_event() RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public`: deriva `entity_type` del `TG_TABLE_NAME`, toma `user_id`/`account_id` de `NEW`, inserta `operation_created` con `event_data` = `{entity_id, entity_type, source:'trigger'}` y `ON CONFLICT DO NOTHING`; luego intenta `first_operation` con el mismo `ON CONFLICT DO NOTHING`. Retorna `NEW` siempre
- [x] 2.8 Envolver todo el cuerpo del emisor en `BEGIN … EXCEPTION WHEN OTHERS THEN RAISE WARNING 'analytics_emit_operation_event: %', SQLERRM; END;` (patrón degrade-don't-fail de `20260812000001`)
- [x] 2.9 `REVOKE ALL ON FUNCTION public.analytics_emit_operation_event() FROM PUBLIC, anon, authenticated` **en el mismo archivo** que la define (gotcha: `DROP`+`CREATE` resetea ACLs)
- [x] 2.10 `DROP TRIGGER IF EXISTS trg_analytics_operation_created ON …` + `CREATE TRIGGER … AFTER INSERT ON … FOR EACH ROW EXECUTE FUNCTION public.analytics_emit_operation_event()` para `sales`, `purchases` y `expenses`
- [x] 2.11 Bloque `DO $$ … $$` de gate auto-limpiante al final de la migración (patrón Parte C de `20260812000001`): anchor sintético, assert de emisión, limpieza hijo→padre, degradación con `RAISE NOTICE` si el contexto no lo permite
- [x] 2.12 Aplicar en local (`npx supabase db reset`) y verificar que la migración corre dos veces seguidas sin error (prueba de idempotencia real, no declarada) — verificado con `supabase stop --no-backup && supabase start` (contenedor 100% fresco) + reaplicación manual de la migración vía `docker exec psql`: segunda corrida exit 0, `DELETE 0` en la limpieza de duplicados, gate embebido PASSED ambas veces.

## 3. Gates SQL de comportamiento — `supabase/tests/test_analytics_events.sql`

> Patrón de `supabase/tests/test_kpis.sql`: acumular fallos en `text[]`, un único `RAISE EXCEPTION` al final. Escribir y ver fallar ANTES del grupo 2.

- [x] 3.1 Esqueleto del archivo con el acumulador `v_failures text[]`, el `RAISE EXCEPTION` final y el bloque de limpieza de anchors hijo→padre
- [x] 3.2 Gate: INSERT de gasto → existe `operation_created` con `entity_id` correcto, `entity_type = 'expense'`, `source = 'trigger'` y `account_id` poblado (extendido con compra → `entity_type='purchase'`, cubre los 3 escenarios de spec)
- [x] 3.3 Gate: primer INSERT del usuario → existe `first_operation`; segundo INSERT (de otro tipo de operación) → sigue existiendo **exactamente uno**
- [x] 3.4 Gate de atomicidad: insertar operación dentro de un savepoint, hacer `ROLLBACK TO SAVEPOINT`, assertar cero eventos huérfanos — implementado como bloque `BEGIN…EXCEPTION` anidado (PL/pgSQL no admite `SAVEPOINT`/`ROLLBACK TO` explícitos; el bloque anidado es su equivalente funcional: subtransacción implícita revertida al capturar la excepción forzada)
- [x] 3.5 Gate de degrade-don't-fail: `ALTER TABLE analytics_events ADD CONSTRAINT tmp_analytics_force_fail CHECK (event_name <> 'operation_created') NOT VALID` (un `CHECK NOT VALID` sí se aplica a filas nuevas), insertar la operación, assertar que la operación existe y que no hay evento, `DROP CONSTRAINT` en el mismo bloque
- [x] 3.6 Gate de ACL/RLS: insertar con `SET LOCAL ROLE authenticated` → el evento se emite igual (prueba que el `REVOKE` de 2.9 no rompe el trigger y que la RLS no bloquea al `DEFINER`) — **gotcha de entorno descubierto**: el CLI local de Supabase (y por ende `supabase start` en CI) crea las tablas con el default ACL del rol `postgres`, que NO otorga INSERT/SELECT a `anon`/`authenticated` (confirmado incluso en un contenedor 100% fresco, `stop --no-backup && start`) — a diferencia de prod, donde `has_table_privilege('authenticated','public.expenses','INSERT')=true`. El gate distingue explícitamente "permission denied for table" (falta el GRANT base, entorno) de una violación real de RLS, degradando solo el primer caso. **Verificado manualmente el comportamiento real**: otorgando temporalmente los mismos GRANTs que tiene prod, el INSERT bajo `authenticated` real emite el evento correctamente (REVOKE de 2.9 no rompe el trigger; RLS de `analytics_events` no bloquea al `SECURITY DEFINER`) — evidencia capturada fuera del gate (no committeada, los GRANTs se revirtieron en la misma sesión).
- [x] 3.7 Gate de idempotencia: emitir dos veces para la misma operación → sigue habiendo un solo `operation_created`
- [x] 3.8 Gate de granularidad: INSERT de N filas en una sentencia → N eventos `operation_created` y un solo `first_operation`
- [x] 3.9 Agregar el paso `psql -v ON_ERROR_STOP=1 … -f supabase/tests/test_analytics_events.sql` a `.github/workflows/KPI_Validation.yml`
- [x] 3.10 Verificar en local que los gates 3.2-3.8 **fallan** contra una base sin la migración y **pasan** con ella — RED: `ERROR: column "account_id" does not exist` (exit 3) contra la base pre-migración; GREEN: los 7 gates (incl. 5, con degradación documentada) pasan tras aplicar la migración.

## 4. Retiro del emisor legacy de aplicación

- [x] 4.1 Eliminar el bloque de emisión de `operation_created` / `first_operation` de `frontend/lib/supabase/services.ts:70-93`, dejando `createExpense` con sólo el INSERT
- [x] 4.2 Buscar cualquier otro emisor de `operation_created` / `first_operation` en el código de aplicación (`frontend/`, `backend/`, `supabase/functions/`) y retirarlo o documentar por qué se conserva — grep confirmó **cero** emisores adicionales en `backend/` y `supabase/functions/` (coincide con el audit del design); `frontend/` solo tenía el de `services.ts`, ya retirado.
- [x] 4.3 Actualizar o retirar los tests de frontend que asserten la emisión legacy de analytics en `createExpense` — no existe ningún test dedicado a `createExpense` ni a su emisión legacy (confirmado por grep); no-op.
- [x] 4.4 Suite de frontend verde (`pnpm vitest run`) — 891/892 passed. 1 falla (`SuscripcionesAmbiguasPage.test.tsx`, redirect de gating no relacionado a expenses/analytics) confirmada **flaky preexistente**: pasa 11/11 en corrida aislada; no reproducible, no tocada por este change.

## 5. Verificación integral post-emisión

- [x] 5.1 En local: crear un gasto vía el endpoint real `POST /expenses` del backend FastAPI y verificar el evento en la base (prueba la ruta que originó el hallazgo F5) — servidor real (`uvicorn backend.main:app`) contra el Postgres local, JWT HS256 real, `POST /expenses` → 201 → `operation_created` + `first_operation` verificados en `analytics_events` con `account_id` poblado. Limpiado.
- [x] 5.2 En local: crear una venta vía `rpc_create_sale_operation` y verificar el evento — `operation_created` con `entity_type='sale'` y `entity_id` = `sales.id` real, verificado.
- [x] 5.3 En local: generar un insight para un usuario con operación previa y verificar que ahora **sí** se emite `umv_reached` (cierra el defecto de la capability `insights`) — vía `rpc_atomic_log_ai_insight` (la RPC viva real, ver hallazgo 1.5): `umv_reached` emitido correctamente tras la venta+gasto previos. Confirma end-to-end que el defecto de UMV está cerrado.
- [x] 5.4 Suite de backend verde con el piso de coverage de CI (`pytest --cov-config` explícito, ≥87%) — 1269 passed, 88.84% (sin cambios: este change no toca `backend/`).
- [ ] 5.5 Tras el merge, verificar en producción (MCP `execute_sql`, lectura): la columna `account_id` existe, los 3 triggers están vivos, los 3 índices creados, la función tiene ACLs revocadas, y aparecen eventos nuevos con `source = 'trigger'`

## 6. Backfill histórico — BLOQUEADO por sign-off de OQ-2

> No ejecutar sin aprobación explícita del PO. La recomendación del design es la Opción A (backfill marcado `source: 'backfill'`); el argumento decisivo es que sin él los usuarios actuales quedan fuera de las cohortes de retención de forma permanente, no transitoria.

- [ ] 6.1 Presentar OQ-2 al PO con ambas opciones, costo/riesgo y la recomendación del design; registrar la decisión
- [ ] 6.2 (Sólo con sign-off) Crear `supabase/migrations/20260915000001_analytics_events_backfill.sql`, idempotente, con la cabecera estándar
- [ ] 6.3 (Sólo con sign-off) `INSERT … SELECT` de `operation_created` derivados de `sales`/`purchases`/`expenses`, con `created_at` = el de la operación, `source = 'backfill'` y `ON CONFLICT DO NOTHING`
- [ ] 6.4 (Sólo con sign-off) Deduplicar contra los eventos legacy existentes por las claves `sale_id`, `purchase_id` y `expense_id`, además del `entity_id` que cubre el índice único
- [ ] 6.5 (Sólo con sign-off) `first_operation` derivado: uno por usuario, fechado en su operación más antigua, con `ON CONFLICT DO NOTHING`
- [ ] 6.6 (Sólo con sign-off) Gate en `test_analytics_events.sql`: correr el backfill dos veces sobre el mismo dataset → mismo conteo de eventos (idempotencia); y ninguna operación con más de un evento
- [ ] 6.7 (Sólo con sign-off) Verificar el delta en producción antes y después: conteo de `first_operation`, activación de `rpc_admin_business_kpis` y cohortes de `rpc_admin_retention_30d`; reportar el salto al PO

## 7. Cierre

- [ ] 7.1 Decidir con el PO si se incluye el índice único parcial para `umv_reached` (OQ-3 del design, una línea de migración) o se difiere
- [ ] 7.2 Actualizar `docs/plan-remediacion-kpis-2026-08-11.md`: marcar C-KPI-4 con su estado y registrar la resolución de OQ-2
- [ ] 7.3 Anotar en el traspaso a C-KPI-5 (`admin-kpi-refresh`) que `analytics_events.account_id` ya está disponible para KPIs por tenant
- [ ] 7.4 PR con checks verdes (esperando `validate-kpis`, no sólo Vercel) y merge
