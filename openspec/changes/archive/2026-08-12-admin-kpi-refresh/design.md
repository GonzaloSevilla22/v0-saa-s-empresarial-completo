## Context

Los paneles admin (`/admin/analytics`, `/admin/metricas`, `/admin/metricas/*`) leen cinco RPCs escritas entre febrero y marzo de 2026 y nunca revisadas desde entonces: `rpc_admin_kpi_overview` y `rpc_admin_retention_30d` (`20260227000100`, reparadas por `20260309000003`), `rpc_admin_business_kpis` (`20260228000400`), `rpc_admin_module_stats` (`20260228000400` → `20260307000200` → `20260307000300` → `20260311000010`) y `rpc_admin_weekly_usage_distribution`. Ninguna fue redefinida después: `20260517000002` sólo fijó `search_path` y `20260823000002`/`20260824000001` sólo tocaron ACLs (`GRANT EXECUTE` a `authenticated`, `REVOKE` de `anon`).

Estado verificado en producción el 2026-08-12 (sólo SELECT de agregados y catálogo, sin impersonación):

| Hecho | Valor | Consecuencia en el panel |
|---|---|---|
| `profiles.plan = 'pro'` | 35 de 35 | MRR `pro × 15` ≈ 525; conversión 100% |
| Cuentas pagas reales | 1 (`billing_plan='pro'`, no exenta) — 1 `plan_upgraded` con `mercadopago_payment_id` y $69.900 ARS el 2026-06-13 | MRR real hoy = 1 × precio de plan |
| Trials PRO vigentes | 33 (vencen 2026-08-30 → 09-04) | Hoy son gratis; el 30-08 empieza el churn |
| Exenciones de cortesía | 1 (`billing_exempt = true`) | Nunca es MRR |
| `subscriptions` / `subscription_intents` | 0 filas | El MRR recurrente de MP todavía no existe como dato |
| `plan_limits.price_monthly` | gratis 0 · inicial 24.900 · avanzado 34.900 · pro 69.900 (ARS) | Existe tabla de precios: no hace falta hardcodear |
| `community.purchase_pools` | 0 filas | `active_pools: 3` es un literal falso |
| `community.posts` / `community.replies` | 5 / 4 filas | `public.posts` ya no existe (C-23) |
| Eventos `post_created` / `reply_created` | 6 / **0** | Contar comunidad por eventos subcuenta |
| `analytics_events` | 1160 filas, `account_id` NULL en el **100%** | Cualquier métrica por cuenta daría 0 |
| Último `operation_created` | mayo 2026 | Agujero de ~3 meses hasta la emisión revivida (PR #383) |
| Usuarios con `first_operation` | 7 | Las cohortes de retención son diminutas |

A eso se suman dos roturas silenciosas: `rpc_admin_module_stats` rama `comunidad` y `get_admin_community_interactions` leen `posts`/`replies` sin calificar bajo `search_path = public`, y esas tablas viven en el schema `community` desde C-23 — el panel `/admin/metricas/comunidad` falla con 42P01 en cuanto se abre; y `/admin/metricas` renderiza dos gráficos contra `kpis.time_series` y `kpis.habit_histogram`, claves que `rpc_admin_business_kpis` no devuelve, así que muestran "Datos insuficientes" desde siempre.

Restricciones: governance MEDIUM (lectura agregada; nada de escritura de billing), TDD estricto con gates SQL más vitest, migraciones idempotentes (el pipeline las aplica dos veces por diseño), timestamp posterior a `20260916000001`, sin superficie frontend nueva.

## Goals / Non-Goals

**Goals:**
- Que cada KPI de cabecera tenga **una sola definición**, escrita en SQL, y que el cliente no re-agregue ni re-filtre nada.
- Que los conteos de personas cuenten personas (`COUNT(DISTINCT user_id)`) y los de eventos cuenten eventos, con la unidad declarada en el nombre del campo.
- Que un panel sin datos diga "no hay datos" en vez de mostrar un cero indistinguible de un hecho del negocio — en particular durante el agujero de telemetría de junio a agosto de 2026.
- Reparar lo que ya está roto (panel de comunidad, gráficos muertos, `active_pools`) reutilizando los helpers existentes, sin escribir motores nuevos.
- Dejar el MRR y la retención **preparados y documentados** para que el sign-off del PO se convierta en un apply corto, no en un rediseño.

**Non-Goals:**
- No se toca ninguna ruta de escritura: ni billing, ni cobros, ni emisión de eventos.
- No se implementa el MRR real ni se cambia la definición de retención sin sign-off explícito (OQ-4, OQ-5).
- No se agregan métricas por cuenta usando `analytics_events.account_id`: hoy es NULL en el 100% de las filas y toda métrica derivada leería 0. Se revisita cuando exista el backfill (OQ-2 de `analytics-events-revival`).
- No se hace backfill de eventos acá — es de otro change.
- No se rediseñan los paneles: mismos componentes, mismas rutas, mismo sistema de diseño.
- No se retira ni se cablea el motor huérfano de `20260430*` más allá del helper de comunidad que este change necesita (ver D8).

## Decisions

### D1 — Las definiciones viven en SQL; el cliente sólo presenta

Todo KPI de cabecera se calcula en la RPC y viaja en `rpc_admin_kpi_overview → summary`. El cliente lee campos, no los deriva. Motivo: cada agregación en el cliente es una segunda definición de la métrica que nadie testea y que se desincroniza de la primera — es exactamente el patrón que produjo los cuatro bugs de este change.

Agregaciones client-side hoy en `admin/analytics/page.tsx`, y su destino:

| Línea (aprox.) | Cálculo actual | Destino |
|---|---|---|
| 111 | `communityActivity.reduce(+active_users)` — suma activos por período **y** por tipo de evento | `summary.community_active_users` = `COUNT(DISTINCT user_id)` del rango |
| 113 | `retentionData.filter(cohort_start < now − 37d)` — ventana hardcodeada | columna `is_mature` de la RPC de retención (D4) |
| 109 | `insightsBreakdown.reduce(+count)` | `summary.total_insights_in_range` (unidad: eventos) |
| 106 | `Math.round(totalUmv / totalActivations × 100)` | `summary.umv_rate` |
| 115-117 | media ponderada de `active_days` por `users_count` | `summary.avg_active_days_per_user_week` |
| 104-105 | `summary.total_activations_in_range` / `total_umv_in_range` | se redefinen como `COUNT(DISTINCT user_id)` sobre el rango completo, no `SUM` de conteos por período |

`rpc_admin_kpi_overview` devuelve `jsonb`: agregar claves a `summary` **no** cambia la firma → `CREATE OR REPLACE` sobre la misma firma, sin riesgo de overload (42725). Los arrays `time_series`, `insights_breakdown` y `community_engagement` se conservan intactos porque alimentan los gráficos.

Alternativa descartada: exponer el promedio de días activos ampliando `rpc_admin_weekly_usage_distribution`. Es `RETURNS TABLE`, así que agregar una columna obliga a `DROP FUNCTION` + `CREATE` + re-GRANT de una función que sólo alimenta un histograma. Se deja como está y el escalar viaja por el `jsonb` del overview.

### D2 — Personas contra eventos: la unidad va en el nombre

`community_active_users` (personas distintas), `total_insights_in_range` (eventos), `community_interactions` (filas transaccionales). El bug de "Usuarios Comunidad" existe porque un campo llamado `active_users` venía agrupado por período y por `event_name`: una persona que postea y responde el mismo día ya cuenta dos veces, y otra vez por cada día del rango. La regla que fija este change: **si el nombre dice `users`, el valor es `COUNT(DISTINCT user_id)` sobre todo el rango**.

### D3 — Cobertura de datos declarada, no inferida

`summary.data_coverage` = `{ last_operation_created_at, last_first_operation_at, operation_events_stale_days }`. El panel muestra un aviso cuando `operation_events_stale_days` supera un umbral (7 días). Motivo: entre ~junio y el 2026-08-12 no hubo emisión de `operation_created`; sin este campo, la frecuencia semanal, la retención y la UMV muestran ceros que se leen como "los usuarios dejaron de operar" cuando lo cierto es "no medimos". El aviso vive en el encabezado de un panel ya montado — no es superficie nueva.

### D4 — La ventana de retención es propiedad de la RPC

`rpc_admin_retention_30d` gana dos columnas: `observation_window_days` (la ventana con la que se evaluó esa cohorte) e `is_mature` (si la cohorte ya vivió esa ventana completa, calculado contra `now()` en SQL). El cliente filtra por `is_mature` y muestra `observation_window_days` como etiqueta; nunca vuelve a hacer aritmética de fechas.

Esto **no** cambia la definición de retención (eso es OQ-5): con la ventana vigente `[30, 37)`, `observation_window_days = 37` y el resultado del panel es idéntico al de hoy. Lo que cambia es de quién es la definición.

Consecuencia mecánica: cambiar `RETURNS TABLE` es cambio de tipo de retorno → Postgres rechaza `CREATE OR REPLACE` (42P13). Hay que `DROP FUNCTION IF EXISTS public.rpc_admin_retention_30d(text, timestamptz, timestamptz)` y crear de nuevo. Y `DROP` borra las ACLs: hay que reaplicar en la **misma** migración el `GRANT EXECUTE ... TO authenticated` de `20260823000002` y el `REVOKE ... FROM anon` de `20260824000001`, más el gate de "exactamente una definición".

### D5 — Comunidad se cuenta desde las tablas transaccionales del schema `community`

Dos fuentes hoy en desacuerdo: eventos (`post_created` 6, `reply_created` **0**) contra tablas (`community.posts` 5, `community.replies` 4). Gana la tabla transaccional: los eventos de comunidad nunca tuvieron un emisor confiable y `analytics-events-revival` cubrió ventas, compras y gastos, no comunidad.

`get_admin_community_interactions` ya implementa exactamente ese conteo — sólo apunta al schema equivocado. Por la regla de reutilización antes que repetición: se repara ese helper (calificando `community.posts`/`community.replies`) y `rpc_admin_business_kpis` **lo llama** en lugar de recontar por su cuenta. `rpc_admin_module_stats` rama `comunidad` se recalifica igual. Se califica el schema explícitamente en vez de ampliar `search_path` a `public, community`: un `search_path` con dos schemas resuelve nombres por orden y vuelve a hacer invisible el próximo movimiento de tablas.

`active_pools` pasa de `3` literal a `COUNT(*)` de `community.purchase_pools` (hoy 0). Un cero verdadero es información; un tres falso no.

### D6 — MRR (OQ-4): tres fuentes posibles, una recomendación

El bloque `freemium` de `rpc_admin_business_kpis` (`pro_users`, `conversion_rate`, `mrr`) queda **gateado completo**, no sólo el `mrr`: las tres cifras dependen de la misma decisión —qué cuenta como cliente pago— y hoy las tres se calculan sobre `profiles.plan`, columna legacy que vale `'pro'` en 35 de 35 perfiles y no la escribe el motor de billing (`get_effective_plan` sobre `accounts` es el canon desde `billing-pro-trial`).

| Opción | Fuente | MRR hoy | A favor | En contra |
|---|---|---|---|---|
| **A. Plan efectivo × tarifa** | `accounts` + `get_effective_plan(id)` + `plan_limits.price_monthly`, excluyendo trials vigentes y `billing_exempt` | **$69.900 ARS** (1 cuenta) | Funciona hoy sin infraestructura nueva; respeta los 4 tiers y la exención; usa la tabla de precios que ya existe; en ARS, como el cobro real | Es MRR *contratado a tarifa de lista*, no cobrado: si mañana hay un descuento pactado, no lo ve |
| **B. Suscripciones vivas de MercadoPago** | `subscriptions` con `status='authorized'`, sumando `amount` | **$0** (tabla vacía) | Es el dinero recurrente real, con el precio efectivamente pactado por cada cliente | Devuelve 0 hasta que el PO active MP real (gate pendiente de `mp-real-subscriptions`); un panel en 0 se lee como roto |
| **C. Cobros realizados** | `billing_events` con `mercadopago_payment_id`, últimos 30 días | **$0** (el único cobro fue el 2026-06-13) | Es caja de verdad, auditable fila por fila | No es MRR sino ingreso del período; con cobros anuales o irregulares oscila salvajemente |

**Recomendación: A ahora, con B como fuente preferente en cuanto exista.** Es decir, una sola RPC que, por cuenta, toma `subscriptions.amount` si hay una suscripción viva y cae a `plan_limits.price_monthly` del plan efectivo si no la hay — hoy el 100% cae al segundo término y el resultado es $69.900 ARS, mañana migra sola sin otro change. Además, el bloque `freemium` pasa a exponer las poblaciones separadas en vez de una sola cifra ambigua: `paying_accounts` (1), `trial_accounts` (33), `exempt_accounts` (1), `free_accounts`, `mrr_ars`, y `trial_pipeline_mrr_ars` (lo que valdrían los 33 trials si convirtieran a su plan de trial — el número que importa antes del 2026-08-30, cuando vencen). La moneda va en el nombre del campo y en la etiqueta del panel: hoy dice `$525` sin decir de qué moneda, y `15` no es ningún precio vigente de la tabla de planes.

**Bloqueado hasta sign-off del PO.** Lo que hay que confirmar: (1) fuente A+B como se describe; (2) trials y exentas **no** son MRR; (3) el panel muestra ARS.

### D7 — Retención (OQ-5 = PA-07): tres definiciones, una recomendación

La visión (`knowledge-base/01_vision_y_objetivos.md` ~47) dice "≥30 días"; la RPC implementa `[30, 37)`; PA-07 (`knowledge-base/10_preguntas_abiertas.md` ~45) está abierta desde entonces.

| Opción | Definición | A favor | En contra |
|---|---|---|---|
| **A. Ventana fija `[30, 37)`** (statu quo) | Retenido si operó entre el día 30 y el 37 tras activarse | Cohortes perfectamente comparables: todas se miden con la misma ventana de 7 días | No responde la visión literal; con 7 usuarios activados totales, una ventana de 7 días da casi siempre 0% y el panel parece muerto |
| **B. Abierta `≥30 días`** | Retenido si operó alguna vez a partir del día 30 | Responde la visión literal; mucho más sensible con pocos datos | Cohortes **no** comparables: una cohorte de marzo tuvo 5 meses de oportunidades y una de julio, 10 días. La serie sube sola con el tiempo y se lee como mejora del producto |
| **C. Abierta censurada a horizonte común `[30, H)`** | Retenido si operó entre el día 30 y el día `H` (parámetro, default 60), y sólo se muestran cohortes con edad ≥ `H` | Comparable **y** literal: todas las cohortes se miran por la misma cantidad de días; A es el caso `H = 37` y B es el caso `H = ∞` | Descarta las cohortes más recientes hasta que maduran; agrega un parámetro a la RPC |

**Recomendación: C con `H = 60` por defecto**, expuesto como parámetro `p_horizon_days` y devuelto en `observation_window_days` (D4 ya prepara al cliente para leerlo). Con `H = 60` la ventana de oportunidad es de 30 días en vez de 7 —sensibilidad suficiente para una base de 7 activados— sin sacrificar comparabilidad, y si el PO prefiere A o B, C degenera exactamente en ellas cambiando un número. El costo es que hoy sólo son visibles las cohortes con más de 60 días de vida.

**Bloqueado hasta sign-off del PO.** El apply de OQ-5 es una segunda migración sobre `rpc_admin_retention_30d` (que ya habrá sido recreada por D4) y cierra PA-07 en `10_preguntas_abiertas.md`.

### D8 — El motor huérfano de `20260430*` no se cablea acá

`get_admin_activation_rate`, `get_admin_umv_rate`, `get_admin_paid_conversion_rate`, `get_admin_insights_breakdown` y `get_admin_community_interactions` existen, están exportados en `frontend/lib/adminAnalytics.ts` y **ningún componente los llama**: los paneles siguen usando el motor viejo. Cablearlos cambiaría en silencio la semántica de tarjetas existentes (por ejemplo `get_admin_activation_rate` toma como denominador los perfiles registrados en el período, no las activaciones del período, como hace hoy la tarjeta), y eso es un cambio de producto, no una corrección.

Decisión: este change repara y consume **sólo** `get_admin_community_interactions`, porque lo necesita y porque está roto. Los otros cuatro quedan documentados como deuda —cablear o retirar— para un change posterior (OQ-6 menor, más abajo). No se borran acá: borrar código muerto que el PO podría querer cablear es una decisión de producto disfrazada de limpieza.

### D9 — Los gráficos muertos de `/admin/metricas` se alimentan de quien sí tiene los datos

`metricas/page.tsx` renderiza `TimeSeriesLinesChart` con `kpis.time_series` y `WeeklyHistogramChart` con `kpis.habit_histogram`, pero `rpc_admin_business_kpis` no devuelve ninguna de las dos claves — siempre cae en "Datos insuficientes". Se corrige del lado del cliente: la página pide también `fetchKpiOverview` (que sí devuelve `time_series`) y `fetchWeeklyUsageDistribution` (que sí devuelve la distribución), en vez de duplicar esas series dentro de `rpc_admin_business_kpis`. Una serie, una fuente.

### D10 — Tipos explícitos: se elimina el `any` de lo que se toca

`admin/analytics/page.tsx` y `metricas/page.tsx` usan `useState<any>`, `catch (err: any)`, `reduce((acc: any, curr: any) ...)` y props `: any` en `KpiCard`/`KpiSummaryCard`; `adminAnalytics.ts` usa `client?: any` y `row: any`. Contra la regla dura del proyecto. Los tipos del payload de cada RPC se definen una vez (`AdminKpiOverview`, `AdminRetentionCohort`, `AdminBusinessKpis`, `AdminWeeklyUsageBucket`) y la derivación del view-model se extrae a una función pura exportada desde `frontend/lib/adminAnalytics.ts` — que es lo que testea vitest, sin montar la página ni mockear Supabase.

Alcance acotado: se tipa lo que este change toca, no todo el árbol `/admin`.

### D11 — Dos migraciones, una idempotente cada una

`M1` (ejecutable, sin gate): `rpc_admin_kpi_overview` (`CREATE OR REPLACE`, misma firma), `rpc_admin_retention_30d` (`DROP` de la firma vieja + `CREATE` + re-`GRANT`/`REVOKE`), `rpc_admin_module_stats` y `get_admin_community_interactions` (`CREATE OR REPLACE`, misma firma, schema calificado), `rpc_admin_business_kpis` (`CREATE OR REPLACE`: sólo el bloque `community` — `active_pools` real y reutilización del helper).

`M2` (gateada por OQ-4/OQ-5, se escribe cuando haya sign-off): bloque `freemium` de `rpc_admin_business_kpis` y ventana de retención. Se escribe **sobre el cuerpo que dejó M1**, no sobre el original.

Ambas: timestamp posterior a `20260916000001`, `CREATE OR REPLACE` / `DROP IF EXISTS` / `GRANT` re-aplicables, cero DDL destructivo sobre datos. El pipeline aplica cada migración dos veces (integración GitHub + `db push` de Actions), así que ningún bloque puede acumular efecto.

## Risks / Trade-offs

- **`DROP FUNCTION` de `rpc_admin_retention_30d` resetea las ACLs y el panel queda en 403 para el admin** → reaplicar `GRANT EXECUTE TO authenticated` y `REVOKE FROM anon` en la misma migración, y verificarlo en el gate SQL (`has_function_privilege`) además del gate global `test_function_acl_gate.sql`.
- **Un `DROP`/`CREATE` mal escrito deja dos overloads (42725) y PostgREST elige el que no es** → gate de "exactamente una definición" por `proname` en `test_admin_kpis.sql`, como en `v3-api-standards`.
- **Los números bajan y se lee como regresión**: comunidad pasa de sumar activos-día a contar personas, pools de 3 a 0, y con OQ-4 el MRR de ~525 a $69.900 ARS con un solo cliente pago → medir y registrar el delta antes/después en producción (sólo SELECT) y anotarlo en el PR, igual que hicieron `v3-reporting-invariants` (+17,53% de revenue) y `kpi-critical-stock-dashboard` (−35,7% de stock crítico).
- **El agujero de eventos de junio a agosto hace que retención, UMV y frecuencia semanal muestren casi cero aunque el motor ya sea correcto** → es precisamente lo que D3 declara; y el valor real de las series depende del backfill (OQ-2 de `analytics-events-revival`), que este change no ejecuta ni bloquea.
- **`analytics_events.account_id` es NULL en el 100% de las filas** → no se construye ninguna métrica sobre esa columna; queda anotado para cuando el backfill la pueble.
- **CI corre sobre una base vacía**: los gates tienen que sembrar sus propios usuarios, eventos, posts y respuestas, y limpiarlos al final — la lección de `20260804000008`/`20260806000002` (limpieza hijo→padre por email del anchor, no-op en producción).
- **Cambiar la ventana de retención rompe la comparabilidad con las capturas históricas del panel** → la ventana viaja en la respuesta (`observation_window_days`) y se muestra como etiqueta, así que ninguna captura queda sin contexto.
- **Trade-off aceptado**: el MRR de la opción A es a tarifa de lista, no a precio pactado. Con un solo cliente pago la diferencia es nula hoy; el término `subscriptions.amount` la absorbe en cuanto MP real esté vivo.

## Migration Plan

1. **Antes de tocar nada**: capturar en producción (sólo SELECT) los valores actuales de los seis KPIs afectados — usuarios de comunidad, activaciones, UMV, insights, frecuencia semanal, retención de la última cohorte — más `active_pools` y el bloque `freemium`. Es la línea base del delta.
2. **M1** (grupos ejecutables) con sus gates SQL y los tests vitest del mapper. Merge → el pipeline aplica la migración y despliega Vercel.
3. **Verificación post-merge en producción** (sólo SELECT): una definición por función, ACLs intactas, `/admin/metricas/comunidad` responde sin 42P01, y el delta contra la captura del paso 1 registrado en el PR.
4. **Espera del sign-off del PO** sobre OQ-4 y OQ-5. El change **no se archiva** hasta que los grupos gateados estén implementados o el PO los descarte explícitamente — mismo patrón que `kpi-branch-consistency` con OQ-1.
5. **M2** (post sign-off): MRR real y ventana de retención definitiva; cierre de PA-07 en `knowledge-base/10_preguntas_abiertas.md`.

**Rollback**: cada RPC vuelve a su definición previa con `CREATE OR REPLACE` desde las migraciones de origen (`20260227000100`, `20260228000400`, `20260309000003`, `20260311000010`, `20260430000005`), y `rpc_admin_retention_30d` con `DROP` + `CREATE` de la firma original más sus GRANT/REVOKE. No hay migración de datos que revertir: el change es de lectura.

## Open Questions

- **OQ-4 (PO, bloqueante del grupo MRR)**: ¿se adopta la fuente A+B de D6 (plan efectivo × `plan_limits.price_monthly`, con `subscriptions.amount` cuando exista), con trials y exentas excluidas del MRR y el panel etiquetado en ARS?
- **OQ-5 (PO, bloqueante del grupo retención; = PA-07)**: ¿se adopta el horizonte común censurado `[30, H)` con `H = 60` de D7, o se prefiere la ventana fija `[30, 37)` o la abierta `≥30 días`?
- **OQ-6 (menor, no bloqueante)**: los cuatro RPCs de `20260430*` sin consumidor (`get_admin_activation_rate`, `get_admin_umv_rate`, `get_admin_paid_conversion_rate`, `get_admin_insights_breakdown`) — ¿se cablean a los paneles en un change posterior, aceptando el cambio de semántica que eso implica, o se retiran? Este change no los toca.
