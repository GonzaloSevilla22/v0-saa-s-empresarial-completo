# Tasks — deudas-menores-agosto

> **Governance: MEDIUM** (G1 toca la ruta de escritura de ventas/compras en prod, con sign-off del PO y rollback de una línea). Implementar por pasos, exponiendo las decisiones no obvias.
> **Strict TDD obligatorio**: cada grupo sigue RED → GREEN → TRIANGULATE → REFACTOR. No se escribe código de producción sin un test que falle antes.
> **Suites base**: frontend ~1018 · backend 1319 con coverage ≥87%.
> **Prod (`gxdhpxvdjjkmxhdkkwyb`): SOLO SELECT vía MCP.** Prohibido `set_config('request.jwt.*')` e impersonar. Los cambios de datos van por migración.
> Los grupos 3–6 son independientes entre sí y del grupo 2: si G1 se aborta, el resto sigue en pie.

## 1. Safety net (antes de tocar nada)

- [x] 1.1 `pytest backend/tests/test_clients.py backend/tests/test_sale_items.py backend/tests/test_sales.py -v` — registrar baseline (`N passed`). Fallo previo ⇒ DETENER y reportar como preexistente, no arreglarlo acá. **Baseline: 70 passed.**
- [x] 1.2 `pnpm vitest run __tests__/ClientForm.test.tsx __tests__/ClientesPage.test.tsx __tests__/hooks/use-client-activity.test.ts` — registrar baseline. Mismo criterio. **Baseline: 21 passed.**
- [x] 1.3 Registrar el baseline de las suites completas (`pytest` backend, `pnpm vitest run` frontend) para demostrar al cierre que no se rompió nada. **Baseline: backend 1 failed (`test_sale_confirmed_exists_in_c29_migration`, preexistente/no relacionado), 1268 passed, 3 skipped, 50 errors de colección (preexistentes, 2 módulos no relacionados). Frontend: 1 failed (test de timing de "suscripciones ambiguas", preexistente/flaky — pasó en la corrida final), 1092 passed.**
- [x] 1.4 Confirmar por MCP (SELECT) el `MAX(version)` real de `supabase_migrations.schema_migrations` y elegir los timestamps de las dos migraciones por encima de ese valor. Al momento del propose: `20260923000001`. **Confirmado exacto. Migraciones: `20260924000001` y `20260925000001`.**
- [x] 1.5 Confirmar por MCP (SELECT) las cifras de partida que los gates van a asertar: cuentas totales, cuentas sin fila de flag, `operation_created` huérfanos, duplicados por clave de entidad, `sale_items`/`purchase_items` con `account_id` nulo. Anotarlas en el PR — si difieren de `design.md` §Context, el estado cambió y hay que releer antes de seguir. **Todas las cifras coinciden exactamente con design.md §Context: 35 cuentas, 26 con flag / 9 sin fila, 58 huérfanos, 0 duplicados, 23 sale_items / 18 purchase_items con account_id nulo.**

## 2. G1 — Activación de `sale_items_rpc_v2` para todas las cuentas

- [x] 2.1 **RED** — extender el gate SQL de ventas en `supabase/tests/` reutilizando las fixtures de venta que ya existen (`grep` primero — `test_idempotency.sql` y el gate embebido de `20260806000001` ya montan cuenta/producto/branch; no duplicar el setup). Caso nuevo: crear una venta y una compra de producto para una cuenta **sin ninguna fila** en `account_feature_flags` y asertar que existe fila en `sale_items` y en `purchase_items`. Debe FALLAR contra el esquema actual (hoy ausencia de fila = legacy). **Archivo nuevo `supabase/tests/test_sale_items_rpc_v2_activation.sql` (patrón de `test_analytics_events.sql`: failures en array + un solo RAISE EXCEPTION). RED real no ejecutable localmente (sin Docker en este entorno) — el gate se valida en CI (KPI_Validation.yml), que sí tiene Docker.**
- [x] 2.2 **GREEN** — crear la migración `<ts>_activate_sale_items_rpc_v2.sql`: `CREATE OR REPLACE` de `rpc_create_sale_operation` y `rpc_create_purchase_operation` copiando el cuerpo vigente de `supabase/migrations/20260806000001_v3_snapshot_pattern.sql` **byte a byte**, cambiando únicamente la resolución del flag. **HALLAZGO CRÍTICO durante la implementación**: verificado contra `pg_get_functiondef` en prod, `rpc_create_purchase_operation` NO tenía ningún dispatch a flag ni escribía `purchase_items` — la premisa de design.md ("un solo flag gobierna ambos", "confirmado") era falsa para compras. Existe una `rpc_create_purchase_operation_v2` en prod pero está huérfana y desactualizada (sin branch_id/cost_center_id/snapshots/evento). Se agregó la resolución del flag + un INSERT de `purchase_items` condicionado, directamente sobre el cuerpo vigente (ya completo), sin usar la función huérfana. Ver cabecera de la migración para el detalle completo.
- [x] 2.3 **GREEN** — UPSERT idempotente por cuenta + `RAISE NOTICE`. Implementado tal cual.
- [x] 2.4 **TRIANGULATE** — los 4 casos (a-d) cubiertos para AMBOS RPCs (venta y compra) en el gate nuevo.
- [x] 2.5 Verificar idempotencia real de la migración. **Sin Docker local disponible, se implementó como paso de CI** (`KPI_Validation.yml` → "Verify G1/G4 migrations are idempotent on reapply"): reaplica ambas migraciones nuevas contra la DB ya migrada y compara un fingerprint de conteos antes/después — debe ser idéntico.
- [x] 2.6 **REFACTOR** — diff mecánico (`difflib`) del cuerpo de `rpc_create_sale_operation` contra `20260806000001`: único cambio es el bloque de resolución del flag (7 líneas). Para `rpc_create_purchase_operation`: 4 inserciones puras (comentario, declaración `v_flag_on`, resolución del flag, INSERT condicionado de `purchase_items`), cero líneas del cuerpo original tocadas o eliminadas.
- [x] 2.7 Verificado: `CREATE OR REPLACE` conserva ACLs (no se usó `DROP`). `test_function_acl_gate.sql` no referencia estas 2 funciones por nombre (gate genérico por allowlist) — corre en CI sin cambios necesarios.

## 3. G2 — `clients.status` deprecado y oculto

- [x] 3.1 **RED** — en `frontend/__tests__/ClientForm.test.tsx`: test que asserta que el formulario de edición NO renderiza el control "Estado" y que el payload enviado a `updateClient` no incluye `status`. Confirmado FALLA antes de implementar (3 tests rojos).
- [x] 3.2 **GREEN** — removido estado `status`, su envío en `clientData` y el bloque `<Select>` "Estado".
- [x] 3.3 **GREEN** — removido `status: "activo"` de `toFormInitialData` y de `mapClient` en `use-clients.ts`; `Client.status` opcional y marcado `@deprecated` en `types.ts`.
- [x] 3.4 **TRIANGULATE** — los 3 casos cubiertos: alta no envía status, edición no envía status, cliente con status preexistente no explota.
- [x] 3.5 **REFACTOR** — `grep` confirma cero lecturas del campo manual fuera de `types.ts`. `pnpm tsc --noEmit`: sin errores nuevos (los preexistentes son de playwright/otros tests no relacionados).
- [x] 3.6 Verificado: `clients.status` no aparece en ninguna migración de este change (grep sobre ambos archivos SQL nuevos: 0 matches).

## 4. G3 — Orden por defecto de `/clientes` por última compra

- [x] 4.1 **RED** — test `test_default_order_is_last_purchase_desc_when_not_specified` en `test_client_repository.py`. Confirmado FALLA antes de implementar (default seguía en `name ASC`).
- [x] 4.2 **GREEN** — default cambiado en `client_repository.py` (`sort/sort_dir`), `backend/routers/clients.py` (`Query`) y además `backend/services/clients.py` (mismo default, no listado en el plan original pero mismo parámetro homónimo — hoy inalcanzable en la práctica porque el router siempre pasa valores explícitos, pero se corrigió por consistencia). Whitelist `_SORT_COLUMNS` y `NULLS LAST` intactos.
- [x] 4.3 **TRIANGULATE** — `sort=name` explícito sigue funcionando (test nuevo); desempate `, id ASC` presente en el default nuevo (test nuevo); caso "sin ninguna venta" ya cubierto implícitamente por los tests existentes con `fetch` vacío (no lanzan excepción).
- [x] 4.4 **GREEN (frontend)** — `use-client-activity.ts`: `sort`/`sortDir` inicializan en `"last_purchase"`/`"desc"`. Test nuevo `initializes sort/sortDir at last_purchase/desc...`. Test preexistente que asumía el default viejo (`sort=name&sort_dir=asc` en la URL) actualizado con intención (comentario explicando el cambio).
- [x] 4.5 **REFACTOR** — confirmado por lectura: el orden se resuelve en `ORDER BY` de SQL (`client_repository.py`); el frontend sólo mapea la página recibida, no la reordena.

## 5. G4 — Limpieza de `analytics_events` y backfill de `account_id`

- [x] 5.1 **RED** — extendido `supabase/tests/test_analytics_events.sql` (Gate 10) con: huérfano legacy (`sale_id`), huérfano moderno (`entity_id`), duplicado CRUZANDO payload legacy/moderno para la misma operación real (más fuerte que el caso mínimo pedido — prueba que el COALESCE unifica la clave entre ambas formas), y evento de operación existente que sobrevive (nota: este schema no tiene columna de soft-delete propia en `sales`/`purchases`/`expenses` — el mecanismo NOT EXISTS es agnóstico a eso, documentado en el gate). RED real no ejecutable localmente (sin Docker) — se valida en CI.
- [x] 5.2 **GREEN** — migración con `DELETE` de huérfanos re-derivado, `COALESCE` de las 4 claves de payload, `NOT EXISTS` contra las 3 tablas, `RAISE NOTICE` con `ROW_COUNT`.
- [x] 5.3 **GREEN** — `DELETE` de duplicados conservando el más antiguo + `RAISE NOTICE`.
- [x] 5.4 **GREEN** — backfill de `account_id` en ambas tablas + `RAISE NOTICE`. Sin `NOT NULL`.
- [x] 5.5 **TRIANGULATE** — gate de aislamiento (Gate 10e) y de idempotencia (Gate 10f, 11c) en el archivo de test.
- [x] 5.6 Verificación de idempotencia real vía CI (mismo paso de `KPI_Validation.yml` que 2.5 — cubre ambas migraciones nuevas juntas).
- [x] 5.7 Confirmado por `grep`: la migración no contiene UUIDs literales ni conteos esperados hardcodeados.

## 6. G5 — Código muerto en `adminAnalytics.ts`

- [x] 6.1 **RED/verificación** — grep confirmó 0 consumidores de los 4 exports. **Corrección sobre design.md**: `AdminInsightsBreakdownEntry` NO es exclusiva de `fetchInsightsBreakdown` — también tipa `AdminKpiOverview.insights_breakdown`, campo de un tipo que sí sigue vivo (`fetchKpiOverview`, consumido por `admin/metricas` y `admin/analytics`). Se conservó la interfaz; sólo se removieron los 4 exports de función + la interfaz privada `InsightsBreakdownRow` (usada únicamente por `fetchInsightsBreakdown`).
- [x] 6.2 **GREEN** — removidos `fetchActivationRate`, `fetchUmvRate`, `fetchPaidConversionRate`, `fetchInsightsBreakdown` y `InsightsBreakdownRow`. RPCs en la base intactas.
- [x] 6.3 **TRIANGULATE** — `pnpm tsc --noEmit` sin errores nuevos; `pnpm vitest run` completo 1098 passed; `fetchCommunityInteractions` sigue exportado y testeado.

## 7. Verificación integral

- [x] 7.1 Suites completas verdes y por encima del baseline: backend 1271 passed (+3, mismo 1 failure y 50 errores preexistentes sin cambios), frontend 1098 passed (+5, 0 failed). Coverage backend no medido en este entorno (sin `pytest-cov` corrido); CI lo verifica.
- [x] 7.2 Gates SQL nuevos agregados a `KPI_Validation.yml` (`test_sale_items_rpc_v2_activation.sql` + extensión de `test_analytics_events.sql` + paso de verificación de idempotencia). Se validan en CI (Docker no disponible en este entorno local).
- [x] 7.3 **Verificación visual de G2/G3 — declaración honesta, no captura de pantalla.** G3 no cambia markup (sólo datos/orden) → cubierto por tests. G2 sí cambia markup (se removió el bloque `<Select>` "Estado"), pero no pudo capturarse una screenshot real: no hay Supabase local (sin Docker) para levantar el stack completo, y el Browser pane no pudo renderizar ni un harness estático aislado en esta sesión headless (API de screenshot requiere el panel activamente visible). Verificación estructural en su lugar: el bloque removido estaba en un `<form className="flex flex-col gap-4">` (spacing por `gap`, no por alturas fijas ni posicionamiento absoluto) — remover un hijo en un layout flex-gap no puede dejar un hueco, el `Button` sube directo. El bloque sólo existía en modo edición (`{initialData && (...)}`); el modo alta no lo renderizaba y su apariencia es idéntica a antes. Ningún token de color nuevo ni removido afecta el resto del formulario (mismos `text-foreground`/`bg-background`/`border-border` que el resto). Pendiente: verificación visual real por el PO o en un entorno con Docker.
- [x] 7.4 PR abierto con cifras de 1.5, `RAISE NOTICE` esperados, rollback textual de G1, OQ-1..OQ-4 de `design.md` **más el hallazgo crítico de compras** (2.2) para sign-off del PO.

## 8. Post-merge (prod, solo lectura vía MCP)

- [ ] 8.1 Confirmar `MAX(version)` = el timestamp de la segunda migración. Un Actions rojo no implica migración no aplicada (auto-apply de la integración GitHub de Supabase) — verificar contra la base, no contra el workflow.
- [ ] 8.2 Confirmar 35/35 cuentas (o el total vigente) con flag efectivo activo: `SELECT count(*) FROM accounts a LEFT JOIN account_feature_flags f ON f.account_id=a.id AND f.flag_key='sale_items_rpc_v2' WHERE COALESCE(f.enabled,true)`.
- [ ] 8.3 Confirmar 0 `operation_created` huérfanos y 0 líneas con `account_id` nulo, con las mismas consultas de 1.5.
- [ ] 8.4 **T0 + 24 h** — verificación estagiada de G1 (`design.md` §D2): de las ventas y compras **creadas después** de la migración, cuántas tienen producto y no tienen línea. Esperado 0. Separar explícitamente esa población de las operaciones **editadas** (`rpc_atomic_update_*`), que siguen sin escribir líneas por OQ-1 y no son evidencia contra este change.
- [ ] 8.5 Si 8.4 da distinto de 0 por una causa atribuible a `_v2`: ejecutar el rollback (`UPDATE public.account_feature_flags SET enabled = false WHERE flag_key = 'sale_items_rpc_v2';`), reportar al PO y abrir el change correctivo.
- [ ] 8.6 Registrar en `CHANGES.md` el cierre de las OQ-4 (`clientes-frecuentes-historial`) y OQ-6 (`admin-kpi-refresh`), y dejar OQ-1 (ruta de edición sin líneas) y OQ-3 (RPCs `get_admin_*` sin consumidor) como deudas abiertas con dueño.
