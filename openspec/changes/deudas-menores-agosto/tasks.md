# Tasks — deudas-menores-agosto

> **Governance: MEDIUM** (G1 toca la ruta de escritura de ventas/compras en prod, con sign-off del PO y rollback de una línea). Implementar por pasos, exponiendo las decisiones no obvias.
> **Strict TDD obligatorio**: cada grupo sigue RED → GREEN → TRIANGULATE → REFACTOR. No se escribe código de producción sin un test que falle antes.
> **Suites base**: frontend ~1018 · backend 1319 con coverage ≥87%.
> **Prod (`gxdhpxvdjjkmxhdkkwyb`): SOLO SELECT vía MCP.** Prohibido `set_config('request.jwt.*')` e impersonar. Los cambios de datos van por migración.
> Los grupos 3–6 son independientes entre sí y del grupo 2: si G1 se aborta, el resto sigue en pie.

## 1. Safety net (antes de tocar nada)

- [ ] 1.1 `pytest backend/tests/test_clients.py backend/tests/test_sale_items.py backend/tests/test_sales.py -v` — registrar baseline (`N passed`). Fallo previo ⇒ DETENER y reportar como preexistente, no arreglarlo acá.
- [ ] 1.2 `pnpm vitest run __tests__/ClientForm.test.tsx __tests__/ClientesPage.test.tsx __tests__/hooks/use-client-activity.test.ts` — registrar baseline. Mismo criterio.
- [ ] 1.3 Registrar el baseline de las suites completas (`pytest` backend, `pnpm vitest run` frontend) para demostrar al cierre que no se rompió nada.
- [ ] 1.4 Confirmar por MCP (SELECT) el `MAX(version)` real de `supabase_migrations.schema_migrations` y elegir los timestamps de las dos migraciones por encima de ese valor. Al momento del propose: `20260923000001`.
- [ ] 1.5 Confirmar por MCP (SELECT) las cifras de partida que los gates van a asertar: cuentas totales, cuentas sin fila de flag, `operation_created` huérfanos, duplicados por clave de entidad, `sale_items`/`purchase_items` con `account_id` nulo. Anotarlas en el PR — si difieren de `design.md` §Context, el estado cambió y hay que releer antes de seguir.

## 2. G1 — Activación de `sale_items_rpc_v2` para todas las cuentas

- [ ] 2.1 **RED** — extender el gate SQL de ventas en `supabase/tests/` reutilizando las fixtures de venta que ya existen (`grep` primero — `test_idempotency.sql` y el gate embebido de `20260806000001` ya montan cuenta/producto/branch; no duplicar el setup). Caso nuevo: crear una venta y una compra de producto para una cuenta **sin ninguna fila** en `account_feature_flags` y asertar que existe fila en `sale_items` y en `purchase_items`. Debe FALLAR contra el esquema actual (hoy ausencia de fila = legacy).
- [ ] 2.2 **GREEN** — crear la migración `<ts>_activate_sale_items_rpc_v2.sql`: `CREATE OR REPLACE` de `rpc_create_sale_operation` y `rpc_create_purchase_operation` copiando el cuerpo vigente de `supabase/migrations/20260806000001_v3_snapshot_pattern.sql` **byte a byte**, cambiando únicamente la resolución del flag por `SELECT enabled INTO v_flag_on …; v_flag_on := COALESCE(v_flag_on, true);` (`design.md` §D1 — el `COALESCE` va DESPUÉS del `SELECT`, no dentro). Declarar en la cabecera: propósito, sign-off del PO 2026-08-18, "cuerpo preservado byte a byte salvo la resolución del flag", y el comando exacto de rollback.
- [ ] 2.3 **GREEN** — en la misma migración, UPSERT idempotente `INSERT … SELECT a.id, 'sale_items_rpc_v2', true FROM public.accounts a ON CONFLICT (account_id, flag_key) DO UPDATE SET enabled = true;` + `RAISE NOTICE` con la cantidad de cuentas afectadas.
- [ ] 2.4 **TRIANGULATE** — casos adicionales en el gate: (a) cuenta con fila `enabled = false` sigue yendo por el camino legacy (el kill-switch funciona); (b) la línea de servicio (`product_id IS NULL`) NO genera ítem; (c) doble llamada con la misma `idempotency_key` crea una sola venta y un solo `sale_items` (idempotencia intacta); (d) el stock se mueve igual que antes.
- [ ] 2.5 Verificar idempotencia real de la migración: `npx supabase db reset` y reaplicar la migración una segunda vez — exit 0, `ON CONFLICT` sin error, gate PASSED en ambas corridas.
- [ ] 2.6 **REFACTOR** — diff de los dos cuerpos (`git diff` contra el bloque copiado) para probar que sólo cambiaron las líneas del flag. Cualquier otra diferencia es un error de transcripción, no una mejora.
- [ ] 2.7 Verificar que la firma de ambas funciones no cambió y que las ACLs se conservan (`CREATE OR REPLACE` no las resetea): correr `supabase/tests/test_function_acl_gate.sql`.

## 3. G2 — `clients.status` deprecado y oculto

- [ ] 3.1 **RED** — en `frontend/__tests__/ClientForm.test.tsx`: test que asserta que el formulario de edición NO renderiza el control "Estado" y que el payload enviado a `updateClient` no incluye `status`. Debe FALLAR hoy.
- [ ] 3.2 **GREEN** — `frontend/components/forms/client-form.tsx`: remover el estado `status`, su envío en `clientData` y el bloque `<Select>` "Estado" (`design.md` §D6).
- [ ] 3.3 **GREEN** — remover `status: "activo"` de `toFormInitialData` en `frontend/app/(dashboard)/clientes/page.tsx` y de `frontend/hooks/data/use-clients.ts`; volver `Client.status` opcional y marcarlo legacy en `frontend/lib/types.ts`.
- [ ] 3.4 **TRIANGULATE** — casos: alta de cliente (no sólo edición) tampoco envía `status`; la lista sigue mostrando `ClientActivityBadge` con el estado calculado; un cliente con `status` preexistente en la respuesta del backend se renderiza sin error.
- [ ] 3.5 **REFACTOR** — `grep -rn "\.status" frontend/components/clientes frontend/components/forms frontend/hooks/data/use-clients.ts` para confirmar que no quedó ninguna lectura del campo manual. `pnpm tsc --noEmit`.
- [ ] 3.6 Verificar que **ningún dato ni esquema** se tocó: la columna `clients.status` no aparece en ninguna migración de este change.

## 4. G3 — Orden por defecto de `/clientes` por última compra

- [ ] 4.1 **RED** — en `backend/tests/` (suite de clientes ya existente): test de `ClientRepository.list_activity_page(...)` **sin** pasar `sort`/`sort_dir` que asserta orden por `last_purchase_date DESC` con los clientes sin compras al final. Debe FALLAR hoy (default `name ASC`).
- [ ] 4.2 **GREEN** — cambiar el default del parámetro en `backend/repositories/client_repository.py` (`sort: str = "last_purchase"`, `sort_dir: str = "desc"`) y en `backend/routers/clients.py` (`Query("last_purchase")`, `Query("desc")`). **No** tocar la whitelist `_SORT_COLUMNS` ni el `NULLS LAST` ya presente (`design.md` §D7).
- [ ] 4.3 **TRIANGULATE** — casos: `sort=name` explícito sigue funcionando (no se rompió el control del usuario); empate de fecha desempata por `id ASC` y la paginación no repite ni omite filas; cuenta sin ninguna venta devuelve la página ordenada sin error.
- [ ] 4.4 **GREEN (frontend)** — `frontend/hooks/data/use-client-activity.ts` l. 159-160: inicializar `sort`/`sortDir` en `"last_purchase"`/`"desc"` para que el control refleje lo que el servidor devuelve. Test en `__tests__/hooks/use-client-activity.test.ts` que asserta los valores iniciales.
- [ ] 4.5 **REFACTOR** — confirmar por lectura que el orden se sigue resolviendo en SQL y que el frontend no reordena la página recibida.

## 5. G4 — Limpieza de `analytics_events` y backfill de `account_id`

- [ ] 5.1 **RED** — en `supabase/tests/test_analytics_events.sql`: casos que insertan (a) un `operation_created` legacy (`sale_id` + `type`) apuntando a una venta inexistente, (b) uno moderno (`entity_id`) apuntando a una compra inexistente, (c) dos eventos para la misma operación existente, (d) un evento de una operación **soft-deleted**, y asertan tras la limpieza: (a) y (b) borrados, (c) queda el más antiguo, (d) intacto. Debe FALLAR hoy.
- [ ] 5.2 **GREEN** — crear la migración `<ts>_cleanup_analytics_and_line_account_id.sql` con el `DELETE` de huérfanos re-derivado según `design.md` §D4 (`COALESCE` de las **dos** formas de payload, `NOT EXISTS` contra `sales`/`purchases`/`expenses`, acotado a `event_name = 'operation_created'`) + `RAISE NOTICE` con `ROW_COUNT`.
- [ ] 5.3 **GREEN** — en la misma migración, el `DELETE` de duplicados por clave de entidad conservando el `created_at` más antiguo + `RAISE NOTICE`. Hoy es no-op (0 duplicados verificados) — se incluye igual, y el `NOTICE` debe reportar 0 sin fallar.
- [ ] 5.4 **GREEN** — en la misma migración, el backfill de `account_id` de `sale_items` ← `sales` y `purchase_items` ← `purchases` (`design.md` §D5) + `RAISE NOTICE` por tabla. **Sin `NOT NULL`.**
- [ ] 5.5 **TRIANGULATE** — gate de aislamiento: los conteos de `insight_generated`, `first_operation`, `umv_reached` y `post_created` son idénticos antes y después. Gate de idempotencia: reejecutar la migración completa borra 0 y backfillea 0.
- [ ] 5.6 Verificar la migración con `npx supabase db reset` + reaplicación manual (contenedor fresco), leyendo los `RAISE NOTICE` de ambas corridas.
- [ ] 5.7 Confirmar que la migración **no** contiene ningún UUID literal ni ningún conteo esperado hardcodeado (`grep` por dígitos sospechosos y por `'…-…-…'`).

## 6. G5 — Código muerto en `adminAnalytics.ts`

- [ ] 6.1 **RED/verificación** — `grep -rn "fetchActivationRate\|fetchUmvRate\|fetchPaidConversionRate\|fetchInsightsBreakdown\|AdminInsightsBreakdownEntry" frontend/ --include=*.ts --include=*.tsx | grep -v "adminAnalytics.ts:"` debe devolver vacío antes de borrar. Si aparece un consumidor, DETENER: la premisa de la OQ-6 cambió.
- [ ] 6.2 **GREEN** — remover de `frontend/lib/adminAnalytics.ts` los 4 exports y la interfaz `AdminInsightsBreakdownEntry`. **No tocar** las RPCs en la base (`design.md` §D8).
- [ ] 6.3 **TRIANGULATE** — `pnpm tsc --noEmit` + `pnpm vitest run` completo: ninguna suite de admin KPIs se rompe; `fetchCommunityInteractions` (que sí tiene consumidor) sigue exportado y testeado.

## 7. Verificación integral

- [ ] 7.1 Suites completas verdes y **por encima** del baseline de 1.3 (frontend y backend). Coverage backend ≥87%.
- [ ] 7.2 Gates SQL nuevos y preexistentes verdes en `KPI_Validation.yml` (con `-v ON_ERROR_STOP=1`).
- [ ] 7.3 **Verificación visual de G2/G3** en `/clientes` y en el formulario de cliente: desktop **y** mobile, tema claro **y** oscuro. Confirmar que no quedó hueco de layout donde estaba el `<Select>` "Estado" y que el orden por defecto es el nuevo.
- [ ] 7.4 Abrir PR con: cifras de 1.5 (antes), los `RAISE NOTICE` esperados, el comando de rollback de G1 textual, y las OQ-1..OQ-4 de `design.md` para sign-off del PO.

## 8. Post-merge (prod, solo lectura vía MCP)

- [ ] 8.1 Confirmar `MAX(version)` = el timestamp de la segunda migración. Un Actions rojo no implica migración no aplicada (auto-apply de la integración GitHub de Supabase) — verificar contra la base, no contra el workflow.
- [ ] 8.2 Confirmar 35/35 cuentas (o el total vigente) con flag efectivo activo: `SELECT count(*) FROM accounts a LEFT JOIN account_feature_flags f ON f.account_id=a.id AND f.flag_key='sale_items_rpc_v2' WHERE COALESCE(f.enabled,true)`.
- [ ] 8.3 Confirmar 0 `operation_created` huérfanos y 0 líneas con `account_id` nulo, con las mismas consultas de 1.5.
- [ ] 8.4 **T0 + 24 h** — verificación estagiada de G1 (`design.md` §D2): de las ventas y compras **creadas después** de la migración, cuántas tienen producto y no tienen línea. Esperado 0. Separar explícitamente esa población de las operaciones **editadas** (`rpc_atomic_update_*`), que siguen sin escribir líneas por OQ-1 y no son evidencia contra este change.
- [ ] 8.5 Si 8.4 da distinto de 0 por una causa atribuible a `_v2`: ejecutar el rollback (`UPDATE public.account_feature_flags SET enabled = false WHERE flag_key = 'sale_items_rpc_v2';`), reportar al PO y abrir el change correctivo.
- [ ] 8.6 Registrar en `CHANGES.md` el cierre de las OQ-4 (`clientes-frecuentes-historial`) y OQ-6 (`admin-kpi-refresh`), y dejar OQ-1 (ruta de edición sin líneas) y OQ-3 (RPCs `get_admin_*` sin consumidor) como deudas abiertas con dueño.
