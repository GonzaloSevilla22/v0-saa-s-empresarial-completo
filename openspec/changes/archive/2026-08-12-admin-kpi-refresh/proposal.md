## Why

Los paneles de administración (`/admin/analytics` y `/admin/metricas`) son el instrumento con el que el PO decide sobre el producto, y hoy **mienten de forma medible**: "Usuarios Comunidad" suma activos diarios (una persona activa N días cuenta N veces), el MRR es `usuarios con profiles.plan='pro' × 15` sobre una columna legacy que hoy vale `'pro'` en **35 de 35** perfiles de producción (MRR reportado ≈ 525 contra **1 sola cuenta paga real**, un cobro de $69.900 ARS el 2026-06-13), "Pools activos" es el literal `3` cuando `community.purchase_pools` tiene **0 filas**, y el panel `/admin/metricas/comunidad` está **roto desde C-23** porque su RPC sigue leyendo `public.posts`/`public.replies`, tablas que se movieron al schema `community`.

Es el hallazgo F6 del plan de remediación de KPIs (`docs/plan-remediacion-kpis-2026-08-11.md`, Fase 4 · C-KPI-5). La Fase 3 (`analytics-events-revival`, PR #383) ya revivió la emisión de telemetría, así que los motores admin vuelven a tener insumo — pero siguen contando mal lo que reciben, y arrastran un agujero de eventos entre ~junio y 2026-08-12 que ningún panel declara.

## What Changes

**Grupo ejecutable (sin decisión de PO)**

- `rpc_admin_kpi_overview` pasa a resolver en SQL todos los KPIs de cabecera que hoy el cliente re-agrega: usuarios de comunidad como `COUNT(DISTINCT user_id)` del rango completo (no suma de activos por período), activaciones y UMV como conteos distintos sobre el rango, total de insights, tasa UMV y promedio de días activos por usuario-semana.
- `rpc_admin_kpi_overview` expone además **cobertura de datos** (fecha del último `operation_created`, antigüedad en días): los paneles declaran el agujero de eventos en vez de presentar un cero como si fuera un hecho del negocio.
- `rpc_admin_retention_30d` deja de delegar en el cliente la madurez de las cohortes: devuelve `is_mature` y `observation_window_days` calculados en SQL. **BREAKING (contrato de RPC)**: cambia el tipo de retorno → `DROP FUNCTION` + `CREATE` con re-`GRANT` en la misma migración.
- `rpc_admin_module_stats` rama `comunidad` se recalifica a `community.posts`/`community.replies` (panel hoy caído con 42P01) y `get_admin_community_interactions` se repara igual, para que el conteo de comunidad venga de las tablas transaccionales y no de eventos que nunca se emitieron (`reply_created`: 0 eventos contra 4 respuestas reales).
- `rpc_admin_business_kpis` deja de inventar `active_pools = 3`: cuenta pools reales y reutiliza `get_admin_community_interactions` en lugar de recontar comunidad por su cuenta.
- `frontend/app/(dashboard)/admin/analytics/page.tsx` y `metricas/page.tsx` dejan de agregar del lado del cliente y de hardcodear la ventana de 37 días; se tipan (hoy usan `any` en estado, props y callbacks, contra la regla dura del proyecto).
- Se corrigen dos gráficos muertos de `/admin/metricas`: el panel lee `kpis.time_series` y `kpis.habit_histogram`, claves que `rpc_admin_business_kpis` nunca devolvió — siempre muestran "Datos insuficientes".
- Gate nuevo `supabase/tests/test_admin_kpis.sql` en `KPI_Validation.yml` (el workflow lista los archivos de test explícitamente).

**Grupo gateado por sign-off del PO (no se implementa sin decisión)**

- **OQ-4 — MRR real y bloque `freemium`**: `rpc_admin_business_kpis` debe dejar de leer `profiles.plan` y pasar al billing vigente de 4 tiers (`get_effective_plan` + `plan_limits.price_monthly`, con trials y exenciones excluidos del MRR). El diseño presenta 3 fuentes posibles con recomendación; el apply queda bloqueado.
- **OQ-5 (= PA-07) — definición de retención**: la ventana vigente `[30, 37)` días contra el "≥30 días" de la visión (`knowledge-base/01_vision_y_objetivos.md`). El diseño presenta 3 definiciones con tradeoffs y recomendación; el apply queda bloqueado.

**Sin superficie frontend nueva.** No se crean pantallas, rutas ni entradas de menú: cambian los números y las etiquetas de paneles admin ya existentes (`/admin/analytics`, `/admin/metricas`, `/admin/metricas/comunidad`), más un aviso de cobertura de datos dentro del encabezado de un panel ya montado. La verificación visual se limita a esos paneles en desktop y mobile, tema claro y oscuro.

## Capabilities

### New Capabilities
- `admin-analytics-kpis`: motor de KPIs de los paneles de administración — dónde vive cada definición (SQL, no cliente), cómo se cuentan personas contra eventos, de qué fuente sale el MRR, cómo se define la retención por cohorte, y cómo se declara la cobertura de datos cuando la telemetría tiene huecos.

### Modified Capabilities
<!-- Ninguna. Ningún spec vigente en openspec/specs/ describe los paneles admin ni el MRR:
     `billing` cubre gating y planes (no reporting), `insights` y `product-analytics-events`
     cubren la emisión de telemetría (no su lectura agregada), `reporting-invariants` cubre
     los KPIs financieros del tenant (RN-D), no los KPIs de plataforma del admin. -->

## Impact

- **DB (migraciones)**: `rpc_admin_kpi_overview`, `rpc_admin_retention_30d` (DROP+CREATE por cambio de tipo de retorno), `rpc_admin_module_stats`, `rpc_admin_business_kpis`, `get_admin_community_interactions`. Todas tienen historia de ACLs en `20260823000002` (GRANT a `authenticated`) y `20260824000001` (REVOKE de `anon`) que debe reaplicarse en la misma migración. Timestamp posterior a `20260916000001`.
- **Frontend**: `frontend/app/(dashboard)/admin/analytics/page.tsx`, `frontend/app/(dashboard)/admin/metricas/page.tsx`, `frontend/app/(dashboard)/admin/metricas/comunidad/page.tsx`, `frontend/lib/adminAnalytics.ts` (tipos explícitos + mapper puro testeable).
- **CI**: `.github/workflows/KPI_Validation.yml` + `supabase/tests/test_admin_kpis.sql`.
- **Sin impacto en escritura**: ninguna ruta de billing, cobro o emisión de eventos cambia; el change es de lectura agregada. Governance MEDIUM.
- **Datos de producción (verificados 2026-08-12, sólo SELECT)**: 35 cuentas — 33 en trial PRO (vence 2026-08-30/09-04), 1 paga real, 1 exenta de cortesía; `subscriptions` y `subscription_intents` vacías; `analytics_events` con 1160 filas y `account_id` NULL en el 100%; último `operation_created` en mayo 2026.
- **Dependencias**: `analytics-events-revival` (Fase 3) ya en producción. El backfill histórico de eventos (OQ-2 de ese change) sigue pendiente y condiciona el valor —no la corrección— de las series de activación y retención.
