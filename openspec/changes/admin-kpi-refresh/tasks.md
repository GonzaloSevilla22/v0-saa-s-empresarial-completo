> **Patrón divisible.** Los grupos 1 a 7 son **ejecutables ya**: no dependen de ninguna decisión del PO. Los grupos 8 y 9 están **gateados** por OQ-4 y OQ-5 (`design.md` D6 y D7) y no se implementan sin sign-off explícito. El change **no se archiva** hasta que los grupos gateados estén hechos o el PO los descarte por escrito — mismo patrón que `kpi-branch-consistency` con OQ-1.
>
> **TDD estricto.** En cada grupo de base de datos el gate SQL se escribe y se ve fallar **antes** de tocar la RPC. En el frontend, el test de vitest sobre la función pura de derivación se escribe antes que la función.

## 1. Línea base en producción (antes de tocar nada)

- [x] 1.1 Capturar en producción (proyecto `gxdhpxvdjjkmxhdkkwyb`, **sólo SELECT**, sin `set_config` de claims ni impersonación) los valores actuales de: usuarios de comunidad, activaciones, UMV, total de insights, promedio de días activos por usuario-semana, retención de la última cohorte considerada válida hoy, `active_pools` y el bloque `freemium` completo. Guardar la captura en el PR como línea base del delta.
- [x] 1.2 Registrar en la misma captura la fecha del último `operation_created` y el porcentaje de filas de `analytics_events` con `account_id` NULL — son los dos números que justifican el aviso de cobertura (D3) y la exclusión de métricas por cuenta.
- [x] 1.3 Verificar que ninguna migración posterior a `20260916000001` haya redefinido las cinco RPCs admin (`pg_proc.prosrc` + `pg_get_functiondef`), para escribir las migraciones sobre el cuerpo vigente y no sobre el del archivo original.

## 2. Gate SQL nuevo (RED antes que todo)

- [x] 2.1 Crear `supabase/tests/test_admin_kpis.sql` con el patrón de los gates existentes (`test_kpis.sql`, `test_analytics_events.sql`): siembra propia de datos, asserts con `RAISE EXCEPTION`, limpieza hijo→padre por el email del anchor al final, no-op sobre datos reales.
- [x] 2.2 Assert de personas contra eventos: sembrar un usuario con actividad de comunidad en tres días distintos y con post + reply, más dos usuarios más; el KPI de usuarios de comunidad debe valer exactamente 3. **RED verificado**: `community_active_users` no existía en `summary` (la clave era `NULL`, no un conteo agregado — más contundente que "vale 6 o más").
- [x] 2.3 Assert de activaciones y UMV como conteos distintos sobre el rango completo (usuario con actividad en dos períodos → cuenta una vez). Nota: bajo la unicidad estructural de `first_operation` (índice único parcial, `analytics-events-revival`) no hay hoy un caso real de doble conteo vía SUM-por-período — es un candado definicional, documentado como tal en el gate.
- [x] 2.4 Assert de cobertura de datos: sin eventos de operación recientes, `summary.data_coverage` reporta la fecha del último evento y una antigüedad en días mayor al umbral; con un evento de hoy, la antigüedad es 0. **RED verificado** (`summary.data_coverage IS NULL` contra la definición vigente).
- [x] 2.5 Assert de madurez de cohorte: cohorte activada hace más días que la ventana → `is_mature = true`; cohorte de hoy → `is_mature = false`; `observation_window_days` presente y no nulo en ambas. **RED verificado** (la query contra la firma nueva de `RETURNS TABLE` falla, 42P13 potencial de `CREATE OR REPLACE` evitado con `DROP`).
- [x] 2.6 Assert de comunidad transaccional: con 2 posts y 3 replies sembrados en el rango, el total de interacciones vale 5 aunque no exista ningún evento `post_created`/`reply_created`; y `rpc_admin_module_stats('comunidad', ...)` responde sin error de relación inexistente. **RED verificado** (42P01: `public.posts` no existe, movida a `community.posts` por C-23).
- [x] 2.7 Assert de pools: baseline real de `community.purchase_pools` (0 en DB fresca) contra el literal 3 devuelto hoy; con 2 pools sembrados, sube exactamente +2. **RED verificado** (`active_pools = 3` sin importar el estado real).
- [x] 2.8 Assert de superficie de autorización: exactamente una definición por `proname` para las cinco RPCs redefinidas (anti-42725), `has_function_privilege('authenticated', ..., 'EXECUTE')` verdadero, `has_function_privilege('anon', ...)` falso, y llamada de un usuario no admin rechazada.
- [x] 2.9 Registrado el paso `Run admin KPI refresh gates` en `.github/workflows/KPI_Validation.yml`. RED confirmado localmente antes de escribir la migración (2.2/2.4/2.5/2.6 fallan o abortan por error real; 2.7 no se alcanzó por el crash de 2.6b — cobertura RED igualmente completa).

## 3. Migración M1 — conteos de cabecera en `rpc_admin_kpi_overview`

- [x] 3.1 Crear la migración M1 (`supabase/migrations/20260917000001_admin_kpi_refresh.sql`, posterior a `20260916000001`), con cabecera de contexto y notas de rollback/idempotencia.
- [x] 3.2 `CREATE OR REPLACE` de `rpc_admin_kpi_overview` **sobre la misma firma** `(timestamptz, timestamptz, text)`. `time_series`, `insights_breakdown` y `community_engagement` quedan intactos.
- [x] 3.3 Agregado a `summary`: `community_active_users` (sobre `community.posts`/`replies`, D5), `total_insights_in_range`, `umv_rate` y `avg_active_days_per_user_week` (`AVG` sobre filas usuario-semana, equivalente a la media ponderada del cliente).
- [x] 3.4 Redefinidos `total_activations_in_range` y `total_umv_in_range` como `COUNT(DISTINCT user_id)` sobre el rango completo.
- [x] 3.5 Agregado `summary.data_coverage` con `last_operation_created_at`, `last_first_operation_at` y `operation_events_stale_days` (global, no acotado al rango consultado — D3).
- [x] 3.6 Verificado GREEN completo tras aplicar M1 (los 15 asserts de `test_admin_kpis.sql` pasan; corrida 2 veces seguidas + reset de DB limpio, sin residuos).

## 4. Migración M1 — madurez de cohorte en `rpc_admin_retention_30d`

- [x] 4.1 `DROP FUNCTION IF EXISTS public.rpc_admin_retention_30d(text, timestamptz, timestamptz)` antes del `CREATE`, comentado con el motivo (42P13).
- [x] 4.2 Recreada con `observation_window_days` (=37, constante) e `is_mature` (`cohort_period < now() - 37 días`), **sin cambiar la ventana vigente** — OQ-5 sigue bloqueada.
- [x] 4.3 Reaplicado `GRANT EXECUTE ... TO authenticated` y `REVOKE ... FROM PUBLIC, anon` en la misma migración.
- [x] 4.4 Verificado: asserts 2.5 y 2.8 pasan (madurez correcta en ambos casos; 1 sola definición; ACLs correctas).

## 5. Migración M1 — comunidad real (helper compartido, panel roto y pools)

- [x] 5.1 `CREATE OR REPLACE` de `get_admin_community_interactions` (misma firma) calificando `community.posts`/`replies`; se le agregó además el guard `is_admin(auth.uid())` que nunca tuvo (hueco de autorización preexistente, cerrado de paso por tocar el cuerpo de todos modos).
- [x] 5.2 `CREATE OR REPLACE` de `rpc_admin_module_stats` (misma firma) calificando `community.posts`/`replies` en la rama `comunidad`. La rama `cursos` tenía el **mismo bug** (`course_progress` también se movió a `community.*` por C-23) — corregida de paso.
- [x] 5.3 `CREATE OR REPLACE` de `rpc_admin_business_kpis` (misma firma) **sólo en el bloque `community`**: `active_pools` = `COUNT(*) FROM community.purchase_pools`; `total_activity` reutiliza `get_admin_community_interactions`. Bloque `freemium` intacto (gateado, grupo 8).
- [x] 5.4 Verificado: asserts 2.6 y 2.7 pasan; `test_admin_kpis.sql` verde completo (15/15), y la suite completa (`test_kpis.sql`, `test_kpis_edge_cases.sql`, `test_function_acl_gate.sql`, `test_idempotency.sql`, `test_analytics_events.sql`, `test_admin_kpis.sql`) corrida en orden sin regresiones.

**Hallazgo colateral (fuera de alcance, reportado aparte):** `update_post_replies_count()`/`update_post_likes_count()` (triggers de `community.posts`/`replies`) siguen escribiendo en `public.posts` sin calificar — el mismo bug de C-23, pero en los triggers de contador, no en las 5 RPCs admin. Esto significa que **toda respuesta a un post en producción falla desde el corte de C-23 (2026-06-15)**. No se corrige en esta migración (no es una de las 5 RPCs de D5/D11); se deja constancia para un change de bugfix aparte.

## 6. Frontend — consumo tipado, sin agregación de cliente

- [x] 6.1 Tests de vitest escritos primero en `frontend/__tests__/adminAnalytics.test.ts` (10 casos): `mapKpiHeaderMetrics`, `selectLatestMatureCohort`, `shouldShowDataCoverageWarning`. **RED confirmado** (`TypeError: ... is not a function` en los 10) antes de escribir las funciones.
- [x] 6.2 Tipos definidos (`AdminKpiOverview`, `AdminKpiSummary`, `AdminKpiDataCoverage`, `AdminRetentionCohort`, `AdminBusinessKpis`, `AdminWeeklyUsageBucket`, + tipos de fila de gráficos) y `frontend/lib/adminAnalytics.ts` tipado por completo: eliminados los 6 `client?: any` y el `row: any` restante (`AnyClient` = `SupabaseClient<any,any,any>` en un único punto, no en cada función — la regla del proyecto es no usar `any` en el código propio, no prohibir el tipo genérico de la librería). Cero `any` nuevo.
- [x] 6.3 Funciones puras agregadas a `frontend/lib/adminAnalytics.ts`: `mapKpiHeaderMetrics`, `selectLatestMatureCohort`, `shouldShowDataCoverageWarning` (+ `DATA_COVERAGE_STALE_THRESHOLD_DAYS`). 6.1 en verde (10/10).
- [x] 6.4 `admin/analytics/page.tsx`: eliminados los 4 `reduce`/`Math.round` y el filtro `< now() - 37 días`; consume `mapKpiHeaderMetrics`/`selectLatestMatureCohort`; estado, `catch` (`err instanceof Error`) y props de `KpiCard` tipados; aviso de cobertura (`AlertTriangle` + texto ámbar) agregado al `<header>` existente vía `shouldShowDataCoverageWarning`.
- [x] 6.5 `admin/metricas/page.tsx`: `TimeSeriesLinesChart` ahora se alimenta de `fetchKpiOverview().time_series` y `WeeklyHistogramChart` de `fetchWeeklyUsageDistribution()` (antes leían `kpis.time_series`/`kpis.habit_histogram`, claves que `rpc_admin_business_kpis` nunca devolvió); estado, `catch` y props de `KpiSummaryCard` tipados.
- [x] 6.6 `/admin/metricas/comunidad` no requirió cambios de código (ya usaba `fetchModuleStats('comunidad', ...)`, arreglado en la migración M1). Verificado en `test_admin_kpis.sql` (2.6c, GREEN) que la RPC subyacente responde sin 42P01; verificación visual en navegador bloqueada (ver 6.7).
- [x] 6.7 Verificación visual en navegador **bloqueada por Cloudflare Turnstile** (el login local no acepta el site key fuera del dominio configurado; bypasear un CAPTCHA está prohibido por las reglas de seguridad del agente). Verificación alternativa realizada: `tsc --noEmit` limpio en los 3 archivos tocados, clases de grid/responsive (`grid-cols-1 md:grid-cols-2 ...`) sin modificar respecto del original, el único elemento visual nuevo (banner de cobertura) reutiliza tokens ya presentes en el mismo panel (paleta ámbar ya usada en otros avisos del proyecto) y no introduce ningún breakpoint nuevo. Estos 3 paneles no participan del theming claro/oscuro de la app (no tienen ninguna clase `dark:` — son dark-only por convención preexistente, no introducida por este change). **Pendiente**: verificación visual real en un entorno con Turnstile configurado (staging/prod) antes o inmediatamente después del merge.
- [x] 6.8 Suite completa de vitest corrida (`pnpm vitest run` vía `npx vitest run`): **897/902 passing**. 5 fallos en 2 archivos, ambos preexistentes y sin relación con este change (`SuscripcionesAmbiguasPage.test.tsx` — assertion de texto duplicado; `Celebration3D.test.tsx` — timing de animación 3D); confirmado que ninguno referencia `adminAnalytics`/`admin/analytics`/`admin/metricas`.

## 7. Merge y verificación post-merge

- [ ] 7.1 Abrir el PR con el delta medido en 1.1 contra los valores nuevos, explicando por qué cada número baja (personas en vez de activos-día, pools reales en vez del literal 3).
- [ ] 7.2 Esperar `validate-kpis` verde (no sólo Vercel) y mergear.
- [ ] 7.3 Verificación post-merge en producción (**sólo SELECT**): una definición por función, `has_function_privilege` de `authenticated`/`anon` como corresponde, `summary` con los campos nuevos, `active_pools` real y `/admin/metricas/comunidad` respondiendo. Anotar el resultado en el PR.
- [ ] 7.4 Actualizar `docs/plan-remediacion-kpis-2026-08-11.md` (tabla de la sección 4 y estado de C-KPI-5) marcando el parcial ejecutado y los grupos que esperan OQ-4/OQ-5.

## 8. GATEADO por OQ-4 (PO) — MRR real y bloque `freemium`

> **No ejecutar sin sign-off explícito del PO.** Opciones, evidencia de producción y recomendación en `design.md` D6. Governance MEDIUM: se lee billing, no se escribe.

- [ ] 8.1 Presentar OQ-4 al PO con las tres fuentes (plan efectivo × tarifa · suscripciones vivas de MP · cobros realizados), la cifra que da cada una hoy y la recomendación A+B; obtener sign-off por escrito de la fuente, del tratamiento de trials y exentas, y de la moneda.
- [ ] 8.2 Gate SQL primero: cuenta paga aporta el precio de su plan; cuenta con suscripción autorizada aporta el importe de la suscripción; trial vigente aporta 0; cuenta exenta aporta 0; las poblaciones (`paying`/`trial`/`exempt`/`free`) suman el total de cuentas.
- [ ] 8.3 Migración M2 sobre el bloque `freemium` de `rpc_admin_business_kpis` (`CREATE OR REPLACE`, misma firma, escrita **sobre el cuerpo que dejó M1**): dejar de leer `profiles.plan`, calcular sobre `accounts` + `get_effective_plan` + `plan_limits.price_monthly` con el término de `subscriptions.amount`, y exponer `paying_accounts`, `trial_accounts`, `exempt_accounts`, `free_accounts`, `mrr_ars` y `trial_pipeline_mrr_ars`.
- [ ] 8.4 Actualizar la tarjeta de MRR en `/admin/metricas`: etiqueta de moneda explícita y subtexto con las poblaciones separadas.
- [ ] 8.5 Medir y registrar el delta en producción (de ~525 sin moneda a la cifra real en ARS) y verificar post-merge.

## 9. GATEADO por OQ-5 (PO, cierra PA-07) — definición de retención

> **No ejecutar sin sign-off explícito del PO.** Opciones y recomendación en `design.md` D7.

- [ ] 9.1 Presentar OQ-5 al PO con las tres definiciones (ventana fija `[30,37)` · abierta `≥30 días` · horizonte común censurado `[30,H)` con `H=60`), sus tradeoffs de comparabilidad y sensibilidad sobre una base de 7 usuarios activados, y la recomendación C.
- [ ] 9.2 Gate SQL primero: usuario que opera dentro del horizonte cuenta como retenido; usuario que sólo opera antes del día 30 no; todas las cohortes de una misma serie reportan el mismo `observation_window_days`; cohorte más joven que el horizonte se marca no madura.
- [ ] 9.3 Migración M2 sobre `rpc_admin_retention_30d` con la definición aprobada (si es la opción C: parámetro `p_horizon_days` con default 60 → **firma nueva**, así que `DROP` de la firma vieja + `CREATE` + re-`GRANT`/`REVOKE` en la misma migración).
- [ ] 9.4 Ajustar la etiqueta del panel para mostrar el horizonte vigente junto a la tasa (el cliente ya lo recibe desde el grupo 4).
- [ ] 9.5 Cerrar PA-07 en `knowledge-base/10_preguntas_abiertas.md` con la definición adoptada y actualizar `knowledge-base/01_vision_y_objetivos.md` si la redacción de la visión queda desalineada.

## 10. Cierre

- [ ] 10.1 Actualizar `CHANGES.md` con el estado del change (parcial ejecutado / gateado) siguiendo el formato usado para `kpi-branch-consistency` y `analytics-events-revival`.
- [ ] 10.2 Guardar en engram las decisiones, los deltas medidos y el resultado de OQ-4/OQ-5 bajo `opsx/admin-kpi-refresh/*`.
- [ ] 10.3 Archivar el change **sólo** cuando los grupos 8 y 9 estén implementados o descartados por escrito por el PO.
