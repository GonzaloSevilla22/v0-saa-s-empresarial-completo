# CHANGES — Secuencia de Implementación

> Índice canónico de todos los changes del proyecto **EmprendeSmart** (MVP del EIE — Ecosistema Inteligente para Emprendedores).
> Cada change es atómico: un agente puede implementarlo en una sesión (~4-6 horas).
> **Leer este archivo antes de ejecutar cualquier `/opsx:propose`.**

---

## Cómo usar este documento

1. **Identificar el change**: buscá por tema en el árbol de dependencias o por fase. Cada change tiene un código `C-NN`.
2. **Leer la KB**: cada change lista los archivos de `knowledge-base/` que debés leer antes de proponer.
3. **Proponer**: ejecutá `/opsx:propose <nombre-kebab-del-change>` para crear el change con todos sus artifacts.
4. **Implementar y archivar**: ejecutá `/opsx:apply` y luego `/opsx:archive` al terminar.
5. **Marcar el checkbox**: cambiá `[ ]` a `[x]` en este archivo cuando el change esté archivado.

---

## Árbol de dependencias

```
C-01 billing-schema-migration
│
└── C-02 plan-gating-engine
    │
    ├── C-03 grace-period-logic
    │   └── C-10 subscription-ui-upgrade-flow
    │
    ├── C-04 ai-usage-counters-split
    │   └── C-11 ai-insights-rentabilidad-producto
    │       └── C-13 ai-price-suggestion
    │
    ├── C-05 multi-user-tenant-architecture      ← BLOQUEO MAYOR
    │   ├── C-06 roles-internos-basicos
    │   └── C-07 sucursales-module-pro
    │       └── C-08 stock-multisucursal
    │
    ├── C-09 community-bug-fixes                 ← independiente (bug fix)
    │
    ├── C-12 ai-comparative-reports
    │
    └── C-14 export-module

C-15 backend-data-layer                       ← scaffold ya archivado; esto agrega la capa de datos
│
└── C-16 backend-data-api-migration
    │
    ├── C-17 backend-payments-migration        ← CRITICO (dinero real)
    │
    └── C-18 frontend-decouple-datacontext

── FASE 6: V2.0 Retirada de deuda ──────────────────────────────────────────────────────────

C-19 v20-tenancy-cleanup                      ← CUELLO DE BOTELLA V2 (CRITICO, L)
│                                                incluye refactor backend Python + 11 Edge Functions
├── C-20 v20-sale-items-migration             ← ALTO, M
├── C-21 v20-inventory-unification            ← CRITICO, L
├── C-24 v20-insights-unification             ← BAJO, S
└── C-25 v20-outbox-activation                ← MEDIO, M

C-22 v20-fiscal-identity-clients              ← BAJO, S — independiente
C-23 v20-community-schema-split               ← MEDIO, M — independiente

── FASE 7: V2.1 Operación ────────────────────────────────────────────────────────────────

C-21 v20-inventory-unification ✓
│
└── C-26 v21-branch-as-root                   ← ALTO, M
    ├── C-28 v21-cash-session                 ← MEDIO, M
    └── C-29 v21-quote-salesorder             ← MEDIO, M (también depende C-20)
        └── C-30 v21-customer-supplier-accounts ← MEDIO, M

C-22 v20-fiscal-identity-clients ✓, C-26 ✓
│
└── C-27 v21-fiscal-profile                   ← CRITICO, M (AFIP)
```

> Nota: workers de IA/OCR (Edge Functions: `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador`, `fair-advisor`, `invoice-ocr`) **NO se migran en esta fase** — permanecen como Supabase Edge Functions (ver DEC-15). Pospuesto hasta contar con presupuesto para Render paid y volumen que justifique workers Python (ARQ/LangChain).
>
> **Scaffolding archivado**: el change `fastapi-backend-monorepo` (2026-06-06) ya implementó: monorepo `frontend/` + `backend/`, FastAPI `backend/main.py`, auth JWT Supabase (`core/auth.py`, HS256), WebSocket manager (`core/ws_manager.py`, `/ws/{room_id}`), `pnpm-workspace.yaml` y 8 tests. Archivado en `openspec/changes/archive/2026-06-06-fastapi-backend-monorepo/`. La FASE 5 cubre lo **pendiente**.
>
> **Regla de V2 (RN-97 — hard rule):** **Ninguna feature nueva sobre tablas en retirada.** No se agrega lógica a `products.stock`, `sales.product_id` (header flat), `company_id` ni `user_id`-como-tenancy mientras estén activos los changes de V2.0. El orden importa — C-19 (`v20-tenancy-cleanup`) es el cuello de botella de toda la Fase 6: bloquea C-20, C-21, C-24 y C-25.
>
> **Preguntas abiertas que el PO debe responder antes del `/opsx:propose v20-tenancy-cleanup`:** PA-16 (¿refactor backend en C-19 atómico o change paralelo?), PA-17 (¿ventana mantenimiento o zero-downtime?), PA-18 (¿6 filas de `companies` son datos reales?). Ver `knowledge-base/10_preguntas_abiertas.md`.

### Paralelismo por fase

```
GATE 0: inicio (sin dependencias)
  → C-01 billing-schema-migration              [Agente A]
  → C-09 community-bug-fixes                  [Agente B]   ← FORK inmediato

GATE 1: C-01 ✓
  → C-02 plan-gating-engine                   [Agente A]

GATE 2: C-02 ✓                                ← FORK MAYOR
  → C-03 grace-period-logic                   [Agente A]
  → C-04 ai-usage-counters-split              [Agente B]
  → C-05 multi-user-tenant-architecture       [Agente C]

GATE 3: C-02 ✓, C-04 ✓
  → C-11 ai-insights-rentabilidad-producto    [Agente B]
  → C-12 ai-comparative-reports               [Agente B]

GATE 4: C-03 ✓
  → C-10 subscription-ui-upgrade-flow         [Agente A]

GATE 5: C-05 ✓                                ← FORK
  → C-06 roles-internos-basicos               [Agente C]
  → C-07 sucursales-module-pro                [Agente C — si C-05 ✓]

GATE 6: C-07 ✓
  → C-08 stock-multisucursal                  [Agente C]

GATE 7: C-11 ✓
  → C-13 ai-price-suggestion                  [Agente B]

GATE 8: C-02 ✓
  → C-14 export-module                        [Agente A]

GATE 9: scaffold archivado (fastapi-backend-monorepo ✓) — sin dependencia en C-01..C-14
  → C-15 backend-data-layer                   [Agente A]

GATE 10: C-15 ✓
  → C-16 backend-data-api-migration           [Agente A]

GATE 11: C-16 ✓                              ← FORK
  → C-17 backend-payments-migration           [Agente A — requiere aprobación humana]
  → C-18 frontend-decouple-datacontext        [Agente B]

── Fase 6 ──────────────────────────────────────────────────────────────────────────────────

GATE 12: inicio V2.0 (PA-16/PA-17/PA-18 respondidas por PO)   ← FORK V2
  → C-19 v20-tenancy-cleanup                  [Agente A — CUELLO DE BOTELLA]   ← CRITICO
  → C-22 v20-fiscal-identity-clients          [Agente B — paralelo/independiente]
  → C-23 v20-community-schema-split           [Agente C — paralelo/independiente]

GATE 13: C-19 ✓                              ← FORK MAYOR V2
  → C-20 v20-sale-items-migration             [Agente A]
  → C-21 v20-inventory-unification            [Agente B]
  → C-24 v20-insights-unification             [Agente B — si C-21 puede esperar]
  → C-25 v20-outbox-activation                [Agente C]

── Fase 7 ──────────────────────────────────────────────────────────────────────────────────

GATE 14: C-21 ✓                              ← desbloquea rama Branch
  → C-26 v21-branch-as-root                   [Agente A]

GATE 15: C-26 ✓                              ← FORK V2.1
  → C-27 v21-fiscal-profile                   [Agente A — si C-22 ✓; CRITICO AFIP]
  → C-28 v21-cash-session                     [Agente B]
  → C-29 v21-quote-salesorder                 [Agente C — si C-20 ✓]

GATE 16: C-29 ✓
  → C-30 v21-customer-supplier-accounts       [Agente A]
```

### Camino crítico (6 changes originales + 4 Fase 5 + 8 V2 — mínimo irreducible)

```
C-01 → C-02 → C-03 → C-10 → C-05 → C-07*           ← MVP (Fases 1–4, completado)

[scaffold archivado] → C-15 → C-16 → C-17**          ← Fase 5 (completado)
                              └── C-18

C-19 → C-21 → C-26 → C-27***                         ← V2.0/V2.1 camino crítico
C-19 → C-20 → C-29 → C-30                            ← V2.1 rama ventas/cuentas corrientes
```

> `*` C-07 (sucursales) es la feature de mayor valor diferencial del plan PRO.
> `**` C-17 es CRÍTICO (dinero real); requiere aprobación humana explícita antes de cortar el webhook de pagos.
> La cadena C-15 → C-16 → {C-17, C-18} es independiente del camino crítico original.
> `***` C-27 (`v21-fiscal-profile`) es el último CRÍTICO del camino V2: facturación electrónica AFIP, sin la cual la PyME usa la app además de su facturador, no en lugar de (DEC-22).
> C-19 (`v20-tenancy-cleanup`) es el cuello de botella de toda la Fase 6 — bloquea 4 changes en paralelo. No puede iniciarse sin respuesta a PA-16/PA-17/PA-18.

### Plan óptimo con 3 agentes

| Paso | Agente A (Billing/Core) | Agente B (IA/Analytics) | Agente C (Multi-tenant/Módulos) |
|------|------------------------|------------------------|----------------------------------|
| 1 | C-01 billing-schema-migration | C-09 community-bug-fixes | — |
| 2 | C-02 plan-gating-engine | — | — |
| 3 | C-03 grace-period-logic | C-04 ai-usage-counters-split | C-05 multi-user-tenant-architecture |
| 4 | C-10 subscription-ui-upgrade-flow | C-11 ai-insights-rentabilidad-producto | C-06 roles-internos-basicos |
| 5 | C-14 export-module | C-12 ai-comparative-reports | C-07 sucursales-module-pro |
| 6 | — | C-13 ai-price-suggestion | C-08 stock-multisucursal |

**Fase 5 — Migración Backend (secuencia separada; scaffold ya archivado)**

| Paso | Agente A (Backend Python) | Agente B (Frontend) | Agente C |
|------|--------------------------|---------------------|----------|
| 7 | C-15 backend-data-layer | — | — |
| 8 | C-16 backend-data-api-migration | — | — |
| 9 | C-17 backend-payments-migration *(requiere aprobación)* | C-18 frontend-decouple-datacontext | — |

**Fase 6 — V2.0 Retirada de deuda** *(requiere PO responder PA-16/PA-17/PA-18 antes del paso 10)*

| Paso | Agente A (Tenancy/Core) | Agente B (Inventario) | Agente C (Schema/Fiscal) |
|------|------------------------|----------------------|--------------------------|
| 10 | C-19 v20-tenancy-cleanup *(CRITICO — 4-6 días)* | C-22 v20-fiscal-identity-clients | C-23 v20-community-schema-split |
| 11 | C-20 v20-sale-items-migration | C-21 v20-inventory-unification | — |
| 12 | C-25 v20-outbox-activation | C-24 v20-insights-unification | — |

**Fase 7 — V2.1 Operación**

| Paso | Agente A (Branch/Fiscal) | Agente B (Caja) | Agente C (Ventas/Cuentas) |
|------|--------------------------|-----------------|---------------------------|
| 13 | C-26 v21-branch-as-root | — | — |
| 14 | C-27 v21-fiscal-profile *(CRITICO, AFIP)* | C-28 v21-cash-session | C-29 v21-quote-salesorder |
| 15 | — | — | C-30 v21-customer-supplier-accounts |

---

## FASE 1 — Billing y Monetización

> Esta fase es el cuello de botella principal: C-01 y C-02 deben completarse antes de casi todo lo demás. C-09 puede correr en paralelo porque es un bug fix sin dependencias de billing.

### [C-01] `billing-schema-migration`
- **Estado**: `[x]` completado
- **Scope**:
  - Migración SQL: ampliar `profiles.plan` de 2 valores (`'free'`, `'pro'`) a 4 valores (`'gratis'`, `'inicial'`, `'avanzado'`, `'pro'`)
  - Migración SQL: agregar campos a `profiles` — `plan_started_at TIMESTAMPTZ`, `plan_expires_at TIMESTAMPTZ`, `grace_period_ends_at TIMESTAMPTZ`, `billing_provider TEXT`, `billing_subscription_id TEXT`
  - Migración SQL: dividir `insights_used` en dos contadores — `ai_queries_used INTEGER DEFAULT 0`, `ai_advice_used INTEGER DEFAULT 0`, mantener `insights_reset_at`
  - Migración SQL: tabla `plan_limits` (seed con los 4 planes × todos los límites de RN-03) — evita hardcodear límites en código
  - Migración SQL: tabla `billing_events` para audit trail de cambios de plan
  - Actualizar `lib/constants.ts`: reemplazar objeto de límites hardcodeado por fetch de `plan_limits`
  - Actualizar tipos TypeScript en `lib/types.ts`: tipo `Plan = 'gratis' | 'inicial' | 'avanzado' | 'pro'`
  - RLS en `plan_limits`: lectura pública (sin auth), escritura solo admin
  - Tests: verificar que migration no rompe usuarios existentes (todos deben quedar en `'pro'`), verificar seed de `plan_limits`
- **Dependencias**: ninguna
- **Governance**: CRITICO
- **Leer antes**:
  - `knowledge-base/03_actores_y_roles.md` §Planes Comerciales
  - `knowledge-base/05_reglas_de_negocio.md` §RN-01 a RN-05
  - `knowledge-base/04_modelo_de_datos.md` §profiles
  - `knowledge-base/10_preguntas_abiertas.md` §INC-01

---

### [C-02] `plan-gating-engine`
- **Estado**: `[x]` completado
- **Scope**:
  - Hook `usePlanLimits()`: fetch de `plan_limits` por plan del usuario, expone `canDo(feature, currentUsage)` y `limit(feature)`
  - Función `checkPlanLimit(userId, feature)` en `lib/services/planService.ts`: consulta `plan_limits` + uso actual del usuario
  - Actualizar `lib/constants.ts` con los 4 planes y sus límites tal como define RN-03
  - Gating activo en productos: bloquear INSERT si `count(products) >= plan_limits.max_products`
  - Gating activo en clientes: bloquear INSERT si `count(clients) >= plan_limits.max_clients`
  - Gating activo en operaciones mensuales: bloquear INSERT de venta/compra/gasto si `count(ops_this_month) >= plan_limits.max_operations_per_month`
  - Gating activo en historial: filtrar queries de ventas/compras/gastos por `date >= NOW() - plan_limits.history_days`
  - UI: componente `<PlanGateAlert feature="X" />` que muestra CTA de upgrade cuando el límite es alcanzado
  - Feature flags en sidebar: ocultar/mostrar items de navegación según plan (rentabilidad, reportes comparativos, sucursales)
  - Tests: verificar que usuario en `'gratis'` no puede crear el producto #101, ni ver datos de hace 31 días
- **Dependencias**: `C-01`
- **Governance**: CRITICO
- **Leer antes**:
  - `knowledge-base/03_actores_y_roles.md` §RBAC y §Planes Comerciales
  - `knowledge-base/05_reglas_de_negocio.md` §RN-03, §RN-06
  - `knowledge-base/08_arquitectura_propuesta.md` §Gestión de Estado
  - `knowledge-base/06_funcionalidades.md` §Estado por Módulo

---

### [C-03] `grace-period-logic`
- **Estado**: `[x]` completado
- **Scope**:
  - Campo `grace_period_ends_at` ya añadido en C-01; aquí se implementa la lógica de uso
  - Trigger PostgreSQL `trg_set_grace_period`: al INSERT en `profiles`, setear `grace_period_ends_at = NOW() + INTERVAL '60 days'`
  - Edge Function o pg_cron job `downgrade-expired-users`: corre diariamente, busca perfiles donde `grace_period_ends_at < NOW()` y `plan != 'gratis'` y no tienen `billing_subscription_id` activo → downgrade a `'gratis'`, INSERT en `billing_events`
  - Email `grace_expiry_warning` (7 días antes): trigger/cron que detecta `grace_period_ends_at BETWEEN NOW() AND NOW() + 7 days` → INSERT en `email_logs`
  - Email `grace_expiry_final` (día del vencimiento): INSERT en `email_logs` con CTA de upgrade
  - Middleware Next.js: verificar `grace_period_ends_at` en sesión y agregar banner de alerta a la UI
  - Componente `<GracePeriodBanner />`: muestra días restantes y CTA de upgrade
  - Resolver PA-02: documentar respuestas a las 4 sub-preguntas de PA-02 en `knowledge-base/10_preguntas_abiertas.md`
  - Tests: simular vencimiento de gracia, verificar downgrade, verificar emails
- **Dependencias**: `C-02`
- **Governance**: ALTO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-02
  - `knowledge-base/10_preguntas_abiertas.md` §PA-02
  - `knowledge-base/04_modelo_de_datos.md` §email_logs, §Triggers Automáticos
  - `knowledge-base/07_flujos_principales.md` §Flujo 7 (Email Transaccional)

---

### [C-09] `community-bug-fixes`
- **Estado**: `[x]` completado
- **Scope**:
  - Auditoría completa del módulo `app/(dashboard)/comunidad/`: leer componentes, identificar bugs reportados
  - Fixes específicos según PA-04 (preguntas abiertas sobre bugs conocidos) — enumerar en el change una vez relevados
  - Verificar RLS de `posts` y `replies`: lectura pública a usuarios auth, escritura solo plan pro
  - Resolver PA-03: documentar exactamente qué pueden y no pueden hacer usuarios `free` en comunidad
  - Agregar CTA de upgrade en el botón de "Crear post" para usuarios free
  - Tests E2E: crear post como pro, intentar crear como free (debe mostrar CTA), borrar post propio, intentar borrar ajeno (debe fallar)
- **Dependencias**: ninguna
- **Governance**: MEDIO
- **Leer antes**:
  - `knowledge-base/06_funcionalidades.md` §Épica 6
  - `knowledge-base/05_reglas_de_negocio.md` §RN-60, §RN-61
  - `knowledge-base/10_preguntas_abiertas.md` §PA-03, §PA-04
  - `knowledge-base/03_actores_y_roles.md` §RBAC

---

## FASE 2 — IA Avanzada y Contadores

> C-04 puede correr en paralelo con C-03 una vez C-02 está completo.

### [C-04] `ai-usage-counters-split`
- **Estado**: `[x]` completado
- **Scope**:
  - Migración SQL: renombrar `insights_used` a `ai_queries_used`, agregar `ai_advice_used INTEGER DEFAULT 0`
  - Migración SQL: actualizar `insights_reset_at` → `ai_counters_reset_at` (misma columna, rename)
  - Migración SQL: pg_cron job mensual `reset-ai-counters`: primer día de cada mes, setear `ai_queries_used = 0`, `ai_advice_used = 0` en todos los perfiles
  - Actualizar Edge Functions: `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador`, `copiloto-ia` → incrementar `ai_queries_used`
  - Actualizar Edge Functions: `fair-advisor` → incrementar `ai_advice_used`
  - Actualizar `usePlanLimits()` (de C-02) para verificar ambos contadores
  - Resolver PA-05: documentar período de reset en `knowledge-base/10_preguntas_abiertas.md`
  - Tests: generar 6 insights como usuario `gratis` → el 6to debe ser bloqueado con CTA de upgrade
- **Dependencias**: `C-02`
- **Governance**: ALTO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-05, §RN-30 a §RN-34
  - `knowledge-base/04_modelo_de_datos.md` §profiles, §Tablas de IA
  - `knowledge-base/10_preguntas_abiertas.md` §PA-05
  - `knowledge-base/08_arquitectura_propuesta.md` §Capa de Edge Functions

---

### [C-11] `ai-insights-rentabilidad-producto`
- **Estado**: `[x]` completado
- **Scope**:
  - Nueva feature: rentabilidad por producto (disponible solo en `'avanzado'` y `'pro'`)
  - RPC PostgreSQL `rpc_product_profitability(p_user_id, p_period_days)`: calcula por SKU — `total_revenue`, `total_cost`, `gross_margin`, `gross_margin_pct`, `units_sold`, `last_sale_date`
  - Edge Function `ai-rentabilidad`: llama a `rpc_product_profitability` → formatea para OpenAI → genera ranking de top/bottom 5 productos por margen → INSERT en `ai_insights` (type='margen')
  - Page `/rentabilidad`: tabla con ranking de productos por margen real, gráfico bar chart (Recharts), botón "Analizar con IA"
  - Gating UI: ocultar página para `'gratis'` e `'inicial'`, mostrar CTA de upgrade
  - Tests: calcular margen de producto con ventas y compras conocidas, verificar que el resultado es correcto
- **Dependencias**: `C-02`, `C-04`
- **Governance**: MEDIO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-06, §RN-30, §RN-32
  - `knowledge-base/04_modelo_de_datos.md` §sales, §purchases, §products
  - `knowledge-base/06_funcionalidades.md` §Épica 4
  - `knowledge-base/08_arquitectura_propuesta.md` §Patrón de Operaciones Atómicas

---

### [C-12] `ai-comparative-reports`
- **Estado**: `[x]` completado
- **Scope**:
  - Nueva feature: reportes comparativos período vs período (disponible solo en `'avanzado'` y `'pro'`)
  - RPC `rpc_period_comparison(p_user_id, p_period_a_start, p_period_a_end, p_period_b_start, p_period_b_end)`: devuelve ventas totales, gastos totales, operaciones, top productos para ambos períodos
  - Edge Function `ai-comparativo`: llama a la RPC → envía a OpenAI → análisis narrativo de variaciones → INSERT en `ai_insights` (type='general')
  - Page `/reportes/comparativo`: selectores de fecha para 2 períodos, charts lado a lado (Recharts), sección de análisis IA
  - Respetar límite de historial por plan (30 días para `'gratis'`, 12m para `'inicial'`, etc.)
  - Gating UI: ocultar para `'gratis'` e `'inicial'`
  - Tests: comparar dos períodos con datos conocidos, verificar cálculo de delta porcentual
- **Dependencias**: `C-02`, `C-04`
- **Governance**: MEDIO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-03 (historial por plan), §RN-06
  - `knowledge-base/06_funcionalidades.md` §Épica 4
  - `knowledge-base/04_modelo_de_datos.md` §sales, §expenses
  - `knowledge-base/07_flujos_principales.md` §Flujo 4

---

### [C-13] `ai-price-suggestion`
- **Estado**: `[x]` completado
- **Scope**:
  - Nueva feature: sugerencia de precio óptimo por producto (disponible solo en `'avanzado'` y `'pro'`)
  - Edge Function `ai-precio`: recibe `product_id`, consulta historial de ventas del producto (últimos 90 días), elasticidad implícita (variación cantidad vs precio), costos → OpenAI sugiere precio óptimo con argumento narrativo
  - Botón "Sugerir precio IA" en la vista de detalle de producto y en la página de rentabilidad (C-11)
  - Modal con resultado: precio sugerido, margen proyectado, argumento IA
  - INSERT en `ai_insights` (type='oportunidad')
  - Gating UI: ocultar para `'gratis'` e `'inicial'`
  - Tests: verificar que con 0 ventas el modelo retorna fallback gracioso
- **Dependencias**: `C-11`
- **Governance**: MEDIO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-06, §RN-30, §RN-31
  - `knowledge-base/04_modelo_de_datos.md` §products, §sales, §ai_insights
  - `knowledge-base/06_funcionalidades.md` §Épica 4
  - `knowledge-base/08_arquitectura_propuesta.md` §Capa de Edge Functions

---

## FASE 3 — Multi-usuario y Tenant

> C-05 es el change de mayor complejidad estructural del proyecto. Bloquea C-06, C-07 y C-08. Debe planificarse cuidadosamente con el equipo antes de implementar.

### [C-05] `multi-user-tenant-architecture`
- **Estado**: `[x]` completado
- **Scope**:
  - Nuevo concepto: `organizations` (tenant) que agrupa múltiples `auth.users` con un plan compartido
  - Migración SQL: tabla `organizations` — `id UUID PK`, `name TEXT`, `plan TEXT`, `plan_started_at`, `grace_period_ends_at`, `billing_subscription_id`, `owner_id UUID FK auth.users`, `created_at`
  - Migración SQL: tabla `organization_members` — `id UUID PK`, `org_id UUID FK organizations`, `user_id UUID FK auth.users`, `role TEXT ('owner'|'admin'|'member')`, `invited_at`, `joined_at`, UNIQUE(org_id, user_id)
  - Migración SQL: agregar `org_id UUID FK organizations NULLABLE` a `profiles`
  - Definir estrategia de migración de usuarios existentes: cada usuario actual → nueva org individual, `org_id` seteado, `profiles.plan` migra a `organizations.plan`
  - Actualizar RLS en todas las tablas: `user_id = auth.uid()` → `user_id IN (SELECT user_id FROM organization_members WHERE org_id = (SELECT org_id FROM profiles WHERE id = auth.uid()))`
  - Actualizar `lib/supabase/server.ts` y `lib/supabase/client.ts`: incluir `org_id` en contexto de sesión
  - Hook `useOrganization()`: expone org actual, miembros, plan de la org
  - Page `/organizacion`: ver miembros, invitar (hasta el límite del plan), ver rol propio
  - Emails: invitación a organización (INSERT en `email_logs`, template `org_invite`)
  - Tests: usuario owner puede invitar hasta el límite del plan, usuario extra no puede unirse si org está al límite
- **Dependencias**: `C-02`
- **Governance**: CRITICO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-07
  - `knowledge-base/03_actores_y_roles.md` §RBAC, §Planes Comerciales
  - `knowledge-base/04_modelo_de_datos.md` §profiles, §RLS
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-08

---

### [C-06] `roles-internos-basicos`
- **Estado**: `[x]` completado
- **Scope**:
  - Roles internos de organización (disponible en `'avanzado'` y `'pro'`): `owner`, `admin`, `member`
  - `owner`: acceso completo, puede cambiar plan, puede eliminar org
  - `admin` (plan `'avanzado'`): acceso a todos los módulos, no puede cambiar plan ni eliminar org
  - `member` (plan `'avanzado'`): acceso de solo lectura a reportes y dashboard; no puede crear/editar operaciones financieras
  - Migración SQL: policy RLS diferenciada por `organization_members.role`
  - UI `/organizacion/roles`: listado de miembros con rol, botones de cambio de rol para `owner`
  - Page `/organizacion/invitar`: formulario de email + rol asignado
  - Gating: plan `'avanzado'` solo puede crear roles básicos (owner + member); plan `'pro'` desbloquea admin
  - Tests: member no puede crear venta, admin sí puede, owner puede cambiar rol de admin
- **Dependencias**: `C-05`
- **Governance**: ALTO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-06, §RN-07
  - `knowledge-base/03_actores_y_roles.md` §Futuros Roles
  - `knowledge-base/04_modelo_de_datos.md` §RLS por tabla
  - `knowledge-base/10_preguntas_abiertas.md` §PA-06

---

### [C-07] `sucursales-module-pro`
- **Estado**: `[x]` completado — 2026-06-07
- **Scope**:
  - Módulo sucursales (disponible exclusivamente en `'pro'`)
  - Migración SQL: tabla `branches` — `id UUID PK`, `org_id UUID FK organizations`, `name TEXT`, `address TEXT`, `is_active BOOLEAN DEFAULT TRUE`, `created_at`; UNIQUE(org_id, name)
  - Migración SQL: agregar `branch_id UUID FK branches NULLABLE` a `sales`, `purchases`, `expenses`, `stock_movements`
  - RLS: usuario solo ve sucursales de su org
  - Page `/sucursales`: CRUD de sucursales (hasta 3 para plan PRO según RN-03)
  - Selectores de sucursal en formularios de venta, compra, gasto (dropdown opcional — si no se elige, queda `NULL = "principal"`)
  - Dashboard filtrable por sucursal (filtro dropdown en header)
  - Reporte por sucursal: ventas, gastos, operaciones desglosadas por branch
  - Gating UI: ocultar sección de menú para todos los planes excepto `'pro'`
  - Tests: crear 3 sucursales (límite), intentar crear la 4ta (debe fallar), registrar venta en sucursal, filtrar dashboard por sucursal
- **Dependencias**: `C-05`
- **Governance**: MEDIO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-03 (Sucursales 1/1/1/3), §RN-06
  - `knowledge-base/04_modelo_de_datos.md` §sales, §purchases, §expenses, §stock_movements
  - `knowledge-base/06_funcionalidades.md` §Estado por Módulo
  - `knowledge-base/03_actores_y_roles.md` §Planes Comerciales

---

### [C-08] `stock-multisucursal`
- **Estado**: `[x]` completado — 2026-06-06
- **Scope**:
  - Extensión del módulo de sucursales: stock separado por sucursal (target: septiembre 2026 según RN-03)
  - Migración SQL: tabla `branch_stock` — `id UUID PK`, `product_id UUID FK products`, `branch_id UUID FK branches`, `quantity NUMERIC(15,4)`, `min_stock INTEGER`, UNIQUE(product_id, branch_id)
  - Migración SQL: agregar `branch_id` a `stock_movements` (ya planificado en C-07, aquí se activa la lógica)
  - Actualizar RPC `rpc_create_operation_aggregate`: si `branch_id` está presente, decrementar/incrementar `branch_stock.quantity` en lugar de `products.stock`
  - Trigger `check_low_stock` actualizado: verificar `branch_stock.quantity <= branch_stock.min_stock` por sucursal
  - Page `/sucursales/:id/stock`: inventario de la sucursal con ajustes manuales
  - Transferencia entre sucursales: RPC `rpc_transfer_stock(product_id, from_branch_id, to_branch_id, quantity)` → dos `stock_movements` (transfer_out + transfer_in)
  - Tests: vender en sucursal A reduce stock de A, no de B; transferir de A a B actualiza ambos
- **Dependencias**: `C-07`
- **Governance**: ALTO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-20 a §RN-25
  - `knowledge-base/04_modelo_de_datos.md` §stock_movements, §products
  - `knowledge-base/07_flujos_principales.md` §Flujo 3 (UMV), §Flujo 9 (Ajuste Stock)
  - `knowledge-base/08_arquitectura_propuesta.md` §Patrón de Operaciones Atómicas

---

## FASE 4 — Upgrade Flow y Exportaciones

### [C-10] `subscription-ui-upgrade-flow`
- **Estado**: `[x]` completado — 2026-06-09
- **Scope**:
  - Page `/planes`: comparativo visual de los 4 planes con tabla de features, precios y CTA de compra
  - Integración con pasarela de pagos: MercadoPago Checkout Pro (preferido para Argentina) o Stripe — definir en `DEC-04` actualizado
  - Webhook de confirmación de pago: API route `/api/billing/webhook` → verifica firma → UPDATE `organizations.plan`, `plan_started_at`, `billing_subscription_id`, INSERT en `billing_events`
  - Email de confirmación de upgrade: INSERT en `email_logs` (template `plan_upgraded`)
  - Email de confirmación de downgrade voluntario: INSERT en `email_logs` (template `plan_downgraded`)
  - Page `/facturacion`: historial de pagos, plan actual, botón de cancelar suscripción
  - Webhook de cancelación (MercadoPago/Stripe): degradar plan al vencimiento del período pagado
  - Tests: simular webhook de pago exitoso → verificar upgrade de plan, simular pago fallido → plan no cambia
- **Dependencias**: `C-03`
- **Governance**: CRITICO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-02 (gracia), §RN-03, §RN-04
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-04
  - `knowledge-base/07_flujos_principales.md` §Flujo 7 (Email)
  - `knowledge-base/10_preguntas_abiertas.md` §PA-02

---

### [C-14] `export-module`
- **Estado**: `[x]` completado — 2026-06-06
- **Scope**:
  - Feature de exportación de datos según límite del plan (0/3/15/50 por mes para gratis/inicial/avanzado/pro)
  - Migración SQL: tabla `export_logs` — `id UUID PK`, `user_id UUID`, `org_id UUID`, `export_type TEXT`, `file_path TEXT`, `status TEXT`, `created_at`; contador mensual en `profiles.exports_used INTEGER DEFAULT 0`
  - Edge Function `generate-export`: recibe tipo (`sales_csv`, `purchases_csv`, `stock_csv`, `full_report_xlsx`), genera el archivo, lo guarda en Supabase Storage bucket `exports` (privado), retorna URL firmada
  - Botones de exportación CSV en páginas de ventas, compras, gastos, stock
  - Page `/exportaciones`: historial de exportaciones, links de descarga (URL firmada 1 hora)
  - Gating: plan `'gratis'` no puede exportar (bloquear con CTA), resto según límite mensual
  - Tests: exportar CSV de ventas con 3 filas, verificar formato correcto; plan gratis recibe error 403
- **Dependencias**: `C-02`
- **Governance**: MEDIO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-03 (Exportaciones)
  - `knowledge-base/03_actores_y_roles.md` §Planes Comerciales
  - `knowledge-base/08_arquitectura_propuesta.md` §Storage Buckets
  - `knowledge-base/06_funcionalidades.md` §Estado por Módulo

---

## FASE 5 — Migración a Backend Python

> Fase independiente de las anteriores. Puede iniciarse en cualquier momento post-MVP sin bloquear los changes C-01..C-14. Los workers de IA/OCR (Edge Functions `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador`, `fair-advisor`, `invoice-ocr`) **no se migran en esta fase** — se mantienen en Supabase Edge Functions hasta contar con presupuesto (ver DEC-15). La cadena de dependencias es: C-15 → C-16 → {C-17, C-18}.
>
> **Realtime se mantiene en Supabase Realtime (DEC-16); el WebSocket del backend ya scaffoldeado queda reservado como infra futura, sin uso en producción.**
>
> **Scaffolding YA archivado** (`openspec/changes/archive/2026-06-06-fastapi-backend-monorepo/`): el change `fastapi-backend-monorepo` implementó el monorepo `frontend/` + `backend/`, FastAPI `backend/main.py`, auth JWT Supabase (`core/auth.py`, HS256), WebSocket manager (`core/ws_manager.py`, `/ws/{room_id}`), `pnpm-workspace.yaml` y 8 tests. **La FASE 5 cubre lo PENDIENTE**: capa de datos (C-15), migración de API (C-16), pagos (C-17) y desacople de DataContext (C-18). **NO re-crear** `auth.py`, `main.py` ni el health endpoint — ya existen.

### [C-15] `backend-data-layer`
- **Estado**: `[x]` completado — 2026-06-07
- **Scope**:
  - **NO re-crear**: `core/auth.py`, `backend/main.py`, `GET /health`, `core/ws_manager.py` — ya implementados y archivados. Este change agrega la **capa de datos** al backend existente.
  - `core/database.py`: pool `asyncpg` con JWT-passthrough — claims del usuario inyectados vía `SET LOCAL request.jwt.claims` en cada conexión; RLS org-based sigue activa como red de seguridad; NUNCA `service_role` en el backend principal
  - `core/deps.py`: dependency `get_auth_context()` — resuelve org + rol + plan desde `organization_members` (una sola query); cacheable en Redis/Upstash; retorna `AuthContext(user_id, org_id, role, plan)`
  - `repositories/` base: clase base `BaseRepository(db_pool)` con método `_execute(query, *args)` que inyecta JWT-claims; las implementaciones concretas llaman a los RPCs existentes en PostgreSQL
  - `core/errors.py`: mapeo de errores PostgreSQL a mensajes en español — FK violation → "recurso no encontrado"; unique violation → "ya existe"; check violation → "valor fuera de rango"; 23xxx codes completos
  - Integración Sentry (free tier) para error tracking del backend
  - Variables de entorno nuevas: `DATABASE_URL` (asyncpg pool), `REDIS_URL` (Upstash) — `SUPABASE_JWT_SECRET` ya configurada en el scaffold
  - Tests: query con JWT inyectado respeta RLS (cross-org → 0 filas); `get_auth_context()` resuelve org + rol correctamente para owner, admin y member; error PG FK violation → respuesta 404 con mensaje en español
- **Dependencias**: ninguna (el scaffold ya existe)
- **Governance**: ALTO
- **Leer antes**:
  - `knowledge-base/08_arquitectura_propuesta.md` §"Evolución Arquitectónica: Backend Python/FastAPI", §"Decisión #0 — JWT-passthrough"
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-12, §DEC-13
  - `knowledge-base/04_modelo_de_datos.md` §organization_members
  - `openspec/changes/archive/2026-06-06-fastapi-backend-monorepo/` (contexto del scaffold archivado)

---

### [C-16] `backend-data-api-migration`
- **Estado**: `[x]` completado — 2026-06-07
- **Scope**:
  - Migración de la API de datos via **Strangler Fig con feature flags** — el frontend puede apuntar al nuevo endpoint o al antiguo por flag; nunca corte abrupto
  - **Sub-etapa 1 — LOW risk**: `expenses` + `clients` → routers, schemas Pydantic v2, services con `require_plan()`, repositories que llaman a los RPCs existentes
  - **Sub-etapa 2 — MEDIO risk**: `products` + `branches` + `stock` → mismo patrón; preservar idempotencia (`idempotency_key`), paridad de stock, transferencias entre sucursales (`rpc_transfer_stock`)
  - **Sub-etapa 3 — MEDIO-ALTO risk**: `sales` + `purchases` + `organizations` → mismo patrón; orquesta `rpc_create_operation_aggregate`; verifica counters de plan pre-insert
  - Guards por router: `require_role(["owner", "admin"])` en mutaciones → `member` recibe 403; `require_plan(["inicial", "avanzado", "pro"])` donde aplica
  - Feature flag: variable de entorno `NEXT_PUBLIC_USE_PYTHON_API=true/false`; `DataContext` dirige tráfico al endpoint correcto
  - Tests por router: happy path; `member` intenta mutación → 403; p95 latency ≤ latency actual + 50ms (medido con `pytest-asyncio` + `httpx`)
  - OpenAPI docs en `/docs` (automático FastAPI) y `/redoc`
- **Dependencias**: `C-15`
- **Governance**: ALTO
- **Leer antes**:
  - `knowledge-base/04_modelo_de_datos.md` (completo — entidades a migrar)
  - `knowledge-base/05_reglas_de_negocio.md` (completo — guards y límites de plan)
  - `knowledge-base/08_arquitectura_propuesta.md` §"Backend Python", §"Patrón de Operaciones Atómicas", §"Lo que SÍ migra"
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-06 (idempotencia), §DEC-07 (ledger inmutable)

---

### [C-17] `backend-payments-migration`
- **Estado**: `[x]` completado
- **Scope**:
  - Migrar el webhook de pago (MercadoPago / Stripe, implementado en C-10) de Next.js API Routes a FastAPI con **doble verificación de firma**
  - El nuevo webhook corre en **paralelo** al webhook actual durante la transición; los resultados se comparan (log de discrepancias) antes de hacer el corte
  - `POST /api/billing/webhook`: verifica firma HMAC del provider; valida idempotencia del evento (`billing_events.provider_event_id`); ejecuta `UPDATE organizations.plan`, `plan_started_at`, `billing_subscription_id`; INSERT en `billing_events`
  - Trigger de emails: INSERT en `email_logs` (templates `plan_upgraded`, `plan_downgraded`) via patrón DEC-09 existente
  - **Requiere aprobación humana explícita antes de apagar el webhook Next.js** (dinero real — governance CRITICO)
  - Tests: webhook pago exitoso → plan upgrade correcto; firma inválida → 400 rechazado sin efecto; evento duplicado → idempotente (no doble upgrade); webhook cancelación → downgrade al vencimiento
- **Dependencias**: `C-16`
- **Governance**: CRITICO
- **Leer antes**:
  - `knowledge-base/05_reglas_de_negocio.md` §RN-02, §RN-03, §RN-04
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-09 (patrón email), §DEC-04 (billing)
  - `CHANGES.md` §C-10 (implementación original del webhook)
  - `knowledge-base/04_modelo_de_datos.md` §billing_events, §organizations

---

### [C-18] `frontend-decouple-datacontext`
- **Estado**: `[x]` completado (2026-06-07)
- **Scope**:
  - Eliminar el God Object `contexts/data-context.tsx`; reemplazar con hooks de **React Query** que consumen la API Python (C-16)
  - Un hook por dominio: `useExpenses()`, `useClients()`, `useProducts()`, `useBranches()`, `useStock()`, `useSales()`, `usePurchases()`, `useOrganizations()` — siguiendo el patrón de hooks ya existente en `hooks/`
  - El frontend queda como **UI pura**: consume FastAPI para datos; mantiene conexión directa a Supabase solo para Realtime (WebSocket), Auth (`supabase.auth.*`) y Storage (signed URLs)
  - Apagar feature flags legacy de la migración (C-16) una vez validada la paridad
  - Borrar las Edge Functions de datos migradas (las de IA/OCR se mantienen — ver DEC-15): `create-sale`, `create-purchase`, `delete-product`
  - OpenAPI docs del backend accesibles desde la UI dev en `/docs` (vía proxy Next.js o link)
  - Load testing con k6: 50 usuarios concurrentes → p95 ≤ 500ms en endpoints críticos (`/sales`, `/products`)
  - Tests: cada hook retorna datos correctos mockeando la API Python; invalidación de cache post-mutación funciona
- **Dependencias**: `C-16`
- **Governance**: MEDIO
- **Leer antes**:
  - `knowledge-base/08_arquitectura_propuesta.md` §"Evolución Arquitectónica: Backend Python/FastAPI", §"Lo que NO se migra", §"Modelo híbrido"
  - `knowledge-base/06_funcionalidades.md` §Estado por Módulo
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-15 (IA/OCR pospuesto), §DEC-16 (realtime por WS)
  - `knowledge-base/02_descripcion_general.md` §Stack

---

---

## FASE 6 — V2.0 Retirada de Deuda

> **Ninguna feature nueva sobre tablas en retirada (RN-97).** El orden importa: C-19 es el cuello de botella de toda esta fase — bloquea C-20, C-21, C-24 y C-25. C-22 y C-23 son independientes y pueden correr en paralelo a C-19. Los changes marcados [CRÍTICO] usan Strangler Fig: nueva estructura → backfill → migrar lecturas → drop viejo.
>
> **C-19 completado (2026-06-09)** — PA-16/PA-17/PA-18 resueltas. Antes de proponer C-20, C-21 o C-25 el PO debe responder PA-20, PA-19 y PA-21 respectivamente (ver `knowledge-base/10_preguntas_abiertas.md`).

### [C-19] `v20-tenancy-cleanup`
- **Estado**: `[x]` completado — 2026-06-09 (archivado: `openspec/changes/archive/2026-06-09-v20-tenancy-cleanup`)
- **Scope**:
  - Backfill `account_id` en tablas ERP que lo tienen con NULLs (completar vacíos)
  - Agregar `account_id` a `suppliers` (actualmente solo tiene `company_id`) + backfill via `company_id → accounts` join
  - Actualizar RLS de `suppliers` para usar `account_id` (alinear con `current_account_ids()` + `is_account_writer()`)
  - Refactorizar backend Python: reemplazar `user_id` por `account_id` en los 7 repositories (`sales_repository.py`, `purchase_repository.py`, `product_repository.py`, `expense_repository.py`, `client_repository.py`, `branch_repository.py`, `stock_repository.py`) — 118 ocurrencias totales — y en `core/auth.py` / `core/deps.py`
  - Actualizar `AuthContext` en el backend: agregar `account_id` (reemplaza `org_id` como clave de tenancy en el backend)
  - Actualizar las 11 Edge Functions de IA/OP: `ai-insights`, `ai-resumen`, `ai-comparativo`, `ai-simulador`, `ai-prediccion`, `ai-precio`, `ai-rentabilidad`, `fair-advisor`, `invoice-ocr`, `generate-export`, `ai-quota.ts` — cambiar filtro primario de `user_id` a `account_id`
  - Actualizar hooks frontend con `user_id` como clave de query: `use-products`, `use-posts`, `use-clients`, `use-expenses-query` (4 archivos)
  - Drop `company_id` de las tablas ERP (después de verificar 0 usos activos) — tras ventana de validación post-backfill
  - Drop `user_id` de tablas ERP donde es tenancy (no identidad) — tras ventana de validación
  - Auditar y resolver las 6 filas de `companies` (con el PO): si son reales → migrar a `accounts`; si son prueba → descartar
  - Migración con feature flag en el backend (variable de entorno `V2_TENANCY_ACCOUNT_ID=true`) para Strangler Fig sin downtime
  - Tests: cross-account query devuelve 0 filas con `account_id` correcto; repositorio `sales` pasa test de aislamiento; Edge Function `ai-insights` filtra por `account_id`; 118 ocurrencias confirmadas substituidas (script de búsqueda en CI)
- **Dependencias**: ninguna (puede iniciar tras respuesta del PO a PA-16/PA-17/PA-18)
- **Governance**: CRITICO
- **Leer antes**:
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-17, §DEC-23
  - `knowledge-base/04_modelo_de_datos.md` §accounts, §account_members, §RLS
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §2.4 (118 ocurrencias `user_id`), §3 (interacción Fase 5), §4 sizing paso 1
  - `modelo-dominio-aliadata-v2.md` §7 paso 1, §5.4 (tenancy única)
  - `knowledge-base/10_preguntas_abiertas.md` §PA-16, §PA-17, §PA-18

---

### [C-20] `v20-sale-items-migration`
- **Estado**: `[x]` completado — 2026-06-10 (archivado: `openspec/changes/archive/2026-06-10-v20-sale-items-migration`)
- **Nota**: Grupo 10 (DROP del header plano) **diferido a change propio** — requiere aprobación separada del PO y está bloqueado por la representación de líneas de servicio en las tablas de ítems (product_id NULL, hoy solo existen en el header via COALESCE). Migraciones 20260616000001–09 + 3 hotfixes completas, RPC v2 con flag por cuenta (26/26 ON), EFs deployadas, repos + hooks actualizados, suite backend 85/85 verde, PRs #153/#154/#155 mergeados.
- **Scope** (completado):
  - Backfill: para cada una de las 128 ventas legacy con `product_id NOT NULL` en el header, crear 1 fila en `sale_items` con `variant_id = NULL` (PA-20 resuelta 2026-06-10: variante opcional, sin variantes default) ✓
  - Versionar el RPC `rpc_create_sale_operation`: nueva versión escribe exclusivamente en `sale_items`; versión legacy queda como fallback con feature flag ✓
  - Actualizar `backend/repositories/sales_repository.py`: query paginada migra de `SELECT s.product_id, s.quantity, s.amount` del header a `JOIN sale_items ON s.id = si.sale_id` ✓
  - Actualizar `frontend/hooks/data/use-sales.ts`: mapper que lee de `sale_items` join en lugar de campos flat del header ✓
  - Actualizar Edge Functions que leen `sale.product_id/amount/quantity`: `ai-insights/index.ts`, `ai-precio/index.ts` ✓
  - Vista de compatibilidad temporal en `sales` (`v_sales_flat`) que expone `product_id/amount/quantity` como columnas calculadas — mantiene otras queries sin romper durante la transición ✓
  - Proceso simétrico para `purchases`/`purchase_items`: backfill, RPC versionado, repo, hook ✓
  - Tests: venta creada con nuevo RPC tiene 1 fila en `sale_items`; hook `use-sales` devuelve ítems correctos; venta legacy pre-backfill es accesible; `purchase_items` espeja el comportamiento ✓
  - Drop de `product_id`, `amount`, `quantity`, `total` del header `sales` → **DIFERIDO a change propio** (Group 10, bloqueado)
  - Drop de las columnas equivalentes en `purchases` → **DIFERIDO a change propio** (Group 10, bloqueado)
- **Dependencias**: `C-19` ✓
- **Governance**: ALTO
- **Leer antes**:
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §2.3 (campos planos en ventas), §4 sizing paso 2
  - `modelo-dominio-aliadata-v2.md` §7 paso 2, §5.3 (SaleItem como parte de Sale)
  - `knowledge-base/04_modelo_de_datos.md` §sales, §sale_items, §purchases, §purchase_items
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-06 (idempotencia), §DEC-07 (ledger inmutable)
  - `knowledge-base/10_preguntas_abiertas.md` §PA-20

---

### [C-21] `v20-inventory-unification`
- **Estado**: `[x]` completado — 2026-06-12 (archivado: `openspec/changes/archive/2026-06-12-v20-inventory-unification`). PRs #157 (apply) #158 (fix backfill account_id) #159 (checkpoint #1: DROP Sistema B) #160 (hotfix write-path dual-write) #161 (checkpoint #2: DROP `products.stock`, single-write). `branch_stock` es el único ledger; gate de venta = Σ branch_stock (global, decisión PO); specs `inventory-single-ledger` (nueva) y `branch-stock` (actualizada) sincronizadas.
- **Scope**:
  - Crear Branch "Casa Central" para cada `account_id` sin branches (o cuyo `branch_id` esté NULL en operaciones) — INSERT en `branches` con `is_default = true`
  - Migrar 19 filas de `inventory_stock` y 22 filas de `inventory_movements` a `branch_stock` + `stock_movements` con `branch_id = casa_central_id`
  - Resolver las 6 filas de `warehouses` (PA-19 resuelta 2026-06-10): migrar sus 19 filas de stock a `branch_stock` de Casa Central; los warehouses (auto-generados "Main Warehouse") NO se convierten en branches — se descartan con el drop
  - Vista de compatibilidad `v_products_with_stock`: calcula `products.stock = SUM(quantity) FROM branch_stock WHERE product_id = ?` para preservar lecturas legacy durante la transición
  - Actualizar `backend/repositories/stock_repository.py`: `SELECT stock FROM products WHERE id = $1 AND user_id = $2` → query sobre `branch_stock` con `account_id`; también `StockOut` schema de Pydantic
  - Actualizar los 15 archivos frontend que leen `products.stock` directamente (a través de la vista o cambiando el source del hook `use-products`): `use-products.ts`, `stock/page.tsx`, `product-catalog.tsx`, `sale-form.tsx`, `stock-adjustment-modal.tsx`, `low-stock-alert.tsx`, `product-picker.tsx`, `ai-summary-card.tsx`, `buildBusinessSnapshot.ts`, `aiCopilotService.ts`, `validator.ts`, `importer.ts`, `unit-utils.ts`, `dashboard/page.tsx`, `backend/repositories/stock_repository.py`
  - Drop columna `products.stock` (último paso, tras validar que todo lee la vista o `branch_stock` directamente)
  - Drop tablas `inventory_stock`, `inventory_movements`, `warehouses` (tras migración y validación)
  - Tests: stock total de producto = suma de `branch_stock` filas; venta en sucursal A no afecta stock de sucursal B; importador de CSV escribe en `branch_stock`; vista `v_products_with_stock` devuelve valores consistentes
- **Dependencias**: `C-19`
- **Governance**: CRITICO
- **Leer antes**:
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §2.1 (`products.stock` — 15 archivos frontend), §2.5 (`inventory_stock`/`warehouses`), §4 sizing paso 3
  - `modelo-dominio-aliadata-v2.md` §7 paso 3, §5.2 (Branch como Aggregate Root)
  - `knowledge-base/04_modelo_de_datos.md` §branch_stock, §stock_movements, §products
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-19
  - `knowledge-base/10_preguntas_abiertas.md` §PA-19

---

### [C-22] `v20-fiscal-identity-clients`
- **Estado**: `[x]` completado — 2026-06-10 (archivado: `openspec/changes/archive/2026-06-10-v20-fiscal-identity-clients`)
- **Scope**:
  - Migración SQL: agregar columnas nullable a `clients` — `tax_id TEXT` (CUIT/DNI), `iva_condition TEXT CHECK ('responsable_inscripto','monotributista','exento','consumidor_final')`, `legal_name TEXT`
  - UI: formulario de cliente actualizado con sección "Datos fiscales" (campos opcionales con label `CUIT/DNI`, `Condición IVA`, `Razón social`)
  - Validación de CUIT en frontend: regex `^\d{2}-\d{8}-\d{1}$` + verificación de dígito verificador (módulo 11)
  - Actualizar hook `use-clients`: incluir campos `tax_id`, `iva_condition`, `legal_name` en el mapper
  - Actualizar endpoint backend `clients`: `ClientOut` schema en Pydantic incluye los nuevos campos; `ClientCreate`/`ClientUpdate` los acepta opcionales
  - Tests: crear cliente con CUIT inválido → error de validación; crear cliente sin CUIT → OK (nullable); cliente con CUIT válido → persistido correctamente
- **Dependencias**: ninguna (paralela a C-19, C-23)
- **Governance**: BAJO
- **Leer antes**:
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §H5 (cliente sin identidad fiscal), §4 sizing paso 4
  - `modelo-dominio-aliadata-v2.md` §5.5 (FiscalIdentity como VO compartido), §7 paso 4
  - `knowledge-base/04_modelo_de_datos.md` §clients, §suppliers (referencia de esquema fiscal existente)
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-18, §DEC-22

---

### [C-23] `v20-community-schema-split`
- **Estado**: `[x]` completado — 2026-06-10 (archivado: `openspec/changes/archive/2026-06-10-v20-community-schema-split`). Nota: se usó `ALTER TABLE SET SCHEMA` (no recreación) + vista puente `community.profiles` para el embedding de PostgREST; 16 tablas (incluye `course_progress`, no listada originalmente)
- **Scope**:
  - Crear schema Postgres `community` en el proyecto Supabase
  - Migrar tablas de dominio no-ERP al nuevo schema: `courses`, `course_modules`, `course_lessons`, `course_enrollments`, `lesson_progress`, `posts`, `replies`, `post_likes`, `meetings`, `seguros`, `purchase_pools`, `landing_sections`, `fair_recommendations`, `fair_ai_tools`, `copilot_prompts`
  - Estrategia: en Supabase no existe `ALTER TABLE SET SCHEMA` sin recrear la tabla — se requiere: CREATE TABLE `community.<tabla>` como el schema original + COPY de datos + DROP TABLE `public.<tabla>` + crear FK constraints + recrear RLS policies en el nuevo schema
  - Actualizar todas las referencias en código frontend a las tablas movidas: queries de `posts`, `replies`, `courses`, etc. deben apuntar al schema `community`
  - Actualizar los tipos TypeScript generados (`database.types.ts`) via `supabase gen types typescript`
  - Verificar que el ERP (ventas, compras, stock, productos) no tiene FKs cruzadas hacia las tablas community
  - Tests: crear post → persiste en `community.posts`; inscribirse en curso → `community.course_enrollments`; módulo de ventas no afectado
- **Dependencias**: ninguna (paralela a C-19, C-22)
- **Governance**: MEDIO
- **Leer antes**:
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §H6 (scope creep fuera del ERP), §4 sizing paso 5
  - `modelo-dominio-aliadata-v2.md` §7 paso 5, §2.6 riesgo 4 (módulo comunidad comparte ciclo de deploy con ERP)
  - `knowledge-base/06_funcionalidades.md` §Épica 6 (Comunidad), §Épica 7 (Educación)
  - `knowledge-base/04_modelo_de_datos.md` §Tablas de Comunidad y Educación

---

### [C-24] `v20-insights-unification`
- **Estado**: `[x]` completado — 2026-06-13 (archivado; tabla única `insights` + fix bug RLS)
- **Scope**:
  - Definir schema canónico unificado — decisión: usar el schema de `ai_insights` como base (`message`, `priority`, `type`, `account_id`) por ser el más completo
  - Migrar las 427 filas de `insights` al schema unificado: mapear `content → message`, derivar `account_id` via join `user_id → accounts`, `actionable → priority` ('high' si `actionable = true`)
  - Decisión PO 2026-06-10: **Opción A** — migrar las 427 filas legacy a `ai_insights` y renombrar `ai_insights` → `insights` (nombre definitivo, sin tabla transitoria)
  - Actualizar las Edge Functions que escriben en `ai_insights` (todas las de IA): apuntar al nombre canónico post-renaming
  - Actualizar el frontend que lee de `insights` (si existe — verificar en `use-insights` hook o componentes de dashboard)
  - Drop tabla `insights` legacy tras validar que 0 referencias activas la leen
  - Tests: 427 filas legacy accesibles en el esquema unificado; Edge Function `ai-insights` escribe en tabla correcta; `account_id` correctamente derivado para todas las filas migradas
- **Dependencias**: `C-19` (necesita `account_id` limpio para el backfill de `insights.account_id`)
- **Governance**: BAJO
- **Leer antes**:
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §H7 (insights duplicados), §4 sizing paso 6
  - `modelo-dominio-aliadata-v2.md` §7 paso 6, §5.8 (Insight unificado)
  - `knowledge-base/04_modelo_de_datos.md` §ai_insights, §Tablas de IA
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-21

---

### [C-25] `v20-outbox-activation`
- **Estado**: `[x]` completado — 2026-06-18 (archivado: `openspec/changes/archive/2026-06-18-v20-outbox-activation`)
- **Scope**:
  - La tabla `events` ya existe con RLS habilitado y 0 filas — esta tarea es de wiring, no de creación de infraestructura
  - Implementar relay: función (Edge Function o backend Python) que lee `events WHERE processed_at IS NULL` periódicamente y dispatcha a consumers vía routing por `event_type`
  - Consumer inicial obligatorio: `AuditLog` — INSERT en `audit_logs` por cada evento procesado
  - Consumer inicial: `EmailNotification` — para eventos del tipo `sale_created` / `stock_adjusted` / `plan_changed`
  - Producir eventos desde las mutaciones principales del backend Python: `SaleCreated`, `PurchaseCreated`, `StockAdjusted` — INSERT en `events` dentro de la misma transacción que la mutación (patrón DEC-20)
  - Idempotencia de consumers: reusar tabla `operation_idempotency` con `(event_id, consumer_type)` como clave única
  - Scope del outbox en V2.0: solo `AuditLog` + `EmailNotification` — consumers de IA/reporting postergados a V2.1 (resolver PA-21 con PO antes de proponer)
  - Tests: `SaleCreated` evento → `audit_logs` tiene entrada; evento duplicado procesado dos veces → idempotente (solo 1 fila en `audit_logs`); relay falla con excepción → `events.processed_at` permanece NULL (retry en próxima ejecución)
- **Dependencias**: `C-19` (para que los eventos tengan `account_id` limpio)
- **Governance**: MEDIO
- **Leer antes**:
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §H8 (`events` outbox — 0 filas, infraestructura lista), §4 sizing paso 7
  - `modelo-dominio-aliadata-v2.md` §7 paso 7, §5.9 (Transactional Outbox)
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-09 (patrón email vía DB), §DEC-20 (consistencia transaccional hot path + outbox para el resto)
  - `knowledge-base/04_modelo_de_datos.md` §events, §audit_logs, §operation_idempotency
  - `knowledge-base/10_preguntas_abiertas.md` §PA-21

---

## FASE 7 — V2.1 Operación

> Fase habilitada una vez completada la retirada de deuda. Construye lo nuevo sobre el esquema limpio: Branch como root real, caja, cotizaciones, órdenes de venta, cuentas corrientes y facturación AFIP. C-26 es el prerequisito interno de la mayoría — completar primero.

### [C-26] `v21-branch-as-root`
- **Estado**: `[x]` completado — 2026-06-12 (archivado: `openspec/changes/archive/2026-06-13-v21-branch-as-root`). PRs #164 (propose) #165 (apply). Lifecycle Branch (status active/closed + open/close RPCs, cierre bloqueado con stock o última operativa), StockTransfer como entidad (`stock_transfers` + `transfer_id` en movements), invariante `onHand >= 0` (CHECK + gate per-branch; sin branch → default operativa), `P0422 branch_closed` en operaciones. Backend 124/124, frontend 203/203. Specs `branches`/`branch-stock`/`stock-transfer` sincronizadas. Nota: el invariante exigió UPDATE-then-INSERT en el helper (los CHECK se validan sobre la fila propuesta antes del ON CONFLICT).
- **Scope**:
  - Promover `Branch` a Aggregate Root real con lifecycle completo: comandos `open()` y `close()` para apertura/cierre operacional de la sucursal
  - `BranchStock` con invariante: `onHand >= 0` verificado en la transacción (sin stock negativo)
  - `StockTransfer` como entidad de primer nivel: hoy existe como RPC `rpc_transfer_stock`, convertirlo en dominio con historial propio en `stock_movements` (movement_type = 'transfer_out' / 'transfer_in')
  - Migración SQL: agregar `status TEXT ('active','closed')` y `opened_at TIMESTAMPTZ`, `closed_at TIMESTAMPTZ` a `branches`
  - Actualizar el backend Python `BranchRepository`: incluir comandos de apertura/cierre; `StockTransfer` como transacción atómica
  - UI `/sucursales/:id`: mostrar estado de la sucursal; botón apertura/cierre; listado de transferencias
  - Tests: abrir sucursal → estado 'active'; transferir stock A→B → ambos `branch_stock` actualizados en la misma transacción; intentar vender en sucursal cerrada → error
- **Dependencias**: `C-21`
- **Governance**: ALTO
- **Leer antes**:
  - `modelo-dominio-aliadata-v2.md` §5.2 (Branch como Aggregate Root), §3.2
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-19, §DEC-20
  - `knowledge-base/04_modelo_de_datos.md` §branches, §branch_stock, §stock_movements
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §5 (v21-branch-as-root scope)

---

### [C-27] `v21-fiscal-profile`
- **Estado**: `[x]` completado — 2026-06-12 (archivado: `openspec/changes/archive/2026-06-12-v21-fiscal-profile`). PRs #168 (propose) #169 (design/decisions) #170 (apply — mergeado). Multi-PV con `points_of_sale` + `document_sequences` por PV, `fiscal_documents` con maquina de estados `pending_cae→authorized/rejected`, relay `pg_cron` (`relay-process-pending-cae`), adaptador `WSFEAdapter`/`WSFEStubAdapter` contra ambiente del perfil, `resolve_invoice_type` puro (A/B/C), bucket privado `afip-certs`. Backend 181/181 (57 nuevos), frontend 221/221 (18 nuevos). Specs `fiscal-profile`/`document-sequence`/`afip-fiscal-document` sincronizadas. **Nota: task 5.2 (E2E homologacion ARCA) pendiente del tramite ARCA del PO — no bloqueo merge.**
- **Scope**:
  - `FiscalProfile` como entidad dentro de `Account`/`Organization`: campos `cuit TEXT`, `iva_condition TEXT`, `iibb_condition TEXT`, `punto_de_venta INTEGER`, `certificado_afip TEXT` (referencia a Storage)
  - Migración SQL: tabla `fiscal_profiles` — `id UUID PK`, `account_id UUID FK accounts`, `cuit TEXT NOT NULL`, `iva_condition TEXT`, `punto_de_venta INTEGER`, `created_at`, UNIQUE(account_id)
  - `DocumentSequence` para numeración AFIP sin huecos: tabla `document_sequences` — `(fiscal_profile_id, comprobante_type, last_number INTEGER)` con lock serializado por `SELECT FOR UPDATE`
  - Adaptador WSFE (AFIP) detrás de ACL: interfaz `FiscalDocumentPort` con método `requestCAE(invoice_data) → CAEResponse`; implementación real vs. stub para tests
  - CAE asíncrono: la venta confirma y persiste con `status = 'pending_cae'`; el adaptador AFIP solicita el CAE en background; reintento con backoff en caso de error AFIP (DEC-22)
  - UI `/configuracion/fiscal`: formulario de configuración de perfil fiscal; upload de certificado a Storage
  - **PA-22 ✅ RESUELTA (2026-06-12)**: el adaptador real apunta a **homologación** de ARCA; ambiente como config por cuenta (`AFIPConfiguration.ambiente`); trámites de producción (certificado + punto de venta WSFE) en paralelo, por cuenta emisora — no bloquean el change (ver `knowledge-base/10` §PA-22)
  - Tests: crear `DocumentSequence` para dos `fiscal_profile` en paralelo → sin duplicados (test de lock); `requestCAE` stub → devuelve CAE ficticio; secuencia de números → sin huecos tras 100 calls concurrentes
- **Dependencias**: `C-22`, `C-26`
- **Governance**: CRITICO
- **Leer antes**:
  - `modelo-dominio-aliadata-v2.md` §5.6 (FiscalProfile, DocumentSequence, adaptador AFIP), §3.6
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-22 (AFIP en V2.1, CAE asíncrono), §DEC-18 (FiscalIdentity)
  - `knowledge-base/10_preguntas_abiertas.md` §PA-22
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §5 (v21-fiscal-profile scope)
  - `knowledge-base/04_modelo_de_datos.md` §organizations (estructura de Account existente)

---

### [C-28] `v21-cash-session`
- **Estado**: `[x]` completado — 2026-06-17 (archivado, PR #190; helper intra-tx `c28_register_cash_movement`; hotfix saldo MAX→SUM 2026-06-29, PR #245)
- **Scope**:
  - `Cashbox` — entidad de caja por sucursal: `(id, branch_id, name, currency DEFAULT 'ARS')`
  - `CashSession` — sesión de caja con ciclo de vida: `open(opening_balance)` / `close(closing_balance)` / `arqueo(counted_balance)` → calcula diferencia
  - `CashMovement` — append-only: `(id, session_id, amount, movement_type, reference_id, created_at)`. Tipos: `sale`, `purchase_payment`, `expense`, `advance`, `withdrawal`
  - Migración SQL: tablas `cashboxes`, `cash_sessions`, `cash_movements` con RLS por `account_id` via `branch_id → branches → account_id`
  - Integrar `CashMovement` en el hot path de `SalesOrder.confirm()` (C-29): una venta en efectivo genera un `cash_movement` en la misma transacción
  - UI `/sucursales/:id/caja`: apertura de sesión, listado de movimientos, cierre con arqueo, diferencia visible
  - Tests: abrir sesión → `status = 'open'`; venta en efectivo → `cash_movements` tiene la fila; cerrar sesión → calcular diferencia correctamente; no se puede abrir sesión si hay una abierta en la misma caja
- **Dependencias**: `C-26`
- **Governance**: MEDIO
- **Leer antes**:
  - `modelo-dominio-aliadata-v2.md` §5.7 (CashSession, Cashbox, CashMovement), §3.7
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-20 (consistencia transaccional hot path)
  - `knowledge-base/04_modelo_de_datos.md` §branches
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §5 (v21-cash-session scope)

---

### [C-29] `v21-quote-salesorder`
- **Estado**: `[x]` archivado (2026-06-17, PRs #193 + hotfix #194 mergeados, archivado `2026-06-17-v21-quote-salesorder`)
- **Scope**:
  - `Quote` — cotización con ciclo de vida: `draft()` / `send()` / `accept()` / `expire()` / `reject()`; referencias `sale_items` via `quote_items`
  - `SalesOrder` — orden de venta con `confirm()` transaccional: en una sola transacción → (a) decrementa `branch_stock` por cada ítem, (b) genera `cash_movement` (si pago en efectivo), (c) genera `DocumentSequence` number (si factura), (d) INSERT en `events` outbox
  - Comando `quickSale()` — acceso directo a POS: crea y confirma un `SalesOrder` en un único paso con UI simplificada
  - Migración SQL: tablas `quotes`, `quote_items`, `sales_orders`, `sales_order_items` con RLS
  - Actualizar `rpc_create_sale_operation` (o reemplazarlo): el nuevo `SalesOrder.confirm()` orquesta el hot path completo
  - Vista de retrocompatibilidad: las ventas legacy (`sales` table) siguen accesibles; las nuevas órdenes se crean en `sales_orders`
  - Tests: `quickSale()` de 2 unidades → `branch_stock` decrementa 2; intento de venta con stock 0 → error "stock insuficiente"; `Quote.accept()` → crea `SalesOrder` con mismo items; `SalesOrder.confirm()` falla a mitad → rollback total (cero efectos parciales)
- **Dependencias**: `C-20`, `C-26`
- **Governance**: MEDIO
- **Leer antes**:
  - `modelo-dominio-aliadata-v2.md` §5.3 (Quote, SalesOrder), §3.3, §2.5 (relación Sales→Inventory transaccional)
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-20, §DEC-06 (idempotencia)
  - `knowledge-base/04_modelo_de_datos.md` §sales, §sale_items, §branch_stock
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §5 (v21-quote-salesorder scope)

---

### [C-30] `v21-customer-supplier-accounts`
- **Estado**: `[x]` archivado 2026-06-20
- **Scope**:
  - `CustomerAccount` — cuenta corriente del cliente con ledger append-only: `AccountMovement(id, customer_account_id, amount, balance_after, movement_type, reference_id, created_at)`. Tipos: `sale`, `payment_received`, `credit_note`, `adjustment`
  - Integrar con `SalesOrder.confirm()` (C-29): si el cliente tiene cuenta corriente habilitada, la venta genera un `AccountMovement` en la misma transacción
  - `SupplierAccount` — simétrico: `SupplierAccountMovement` con `payment_made`, `purchase`, `debit_note`
  - Integrar con `PurchaseOrder.receive()` (si existe — si no, con el flujo de compras actual): genera `SupplierAccountMovement`
  - `PaymentReceived` — registro de cobro parcial/total: vincula `CustomerAccount` con la venta correspondiente
  - `PaymentMade` — registro de pago a proveedor: vincula `SupplierAccount` con la compra
  - Migración SQL: tablas `customer_accounts`, `customer_account_movements`, `supplier_accounts`, `supplier_account_movements`, `payments_received`, `payments_made`
  - UI `/clientes/:id/cuenta`: saldo actual, historial de movimientos, registrar cobro
  - UI `/proveedores/:id/cuenta`: simétrico
  - Tests: crear `CustomerAccount`; confirmar venta → `balance_after` correcto; registrar cobro → saldo disminuye; saldo nunca va negativo (invariante); `SupplierAccount` espeja el comportamiento
- **Dependencias**: `C-29`
- **Governance**: MEDIO
- **Leer antes**:
  - `modelo-dominio-aliadata-v2.md` §5.4 (CustomerAccount, SupplierAccount, cuentas corrientes), §3.4
  - `knowledge-base/09_decisiones_y_supuestos.md` §DEC-18 (Customer/Supplier separados)
  - `knowledge-base/04_modelo_de_datos.md` §clients, §suppliers, §sales, §purchases
  - `openspec/explore/2026-06-09-modelo-dominio-v2.md` §5 (v21-customer-supplier-accounts scope)

---

## FASES FUTURAS (placeholder — sin changes numerados aún)

> Estas fases requieren completar V2.0 y V2.1. No se descomponen en changes hasta que las preguntas abiertas relevantes (PA-22, PA-23 y las dudas del PO sobre presupuesto/AFIP) estén resueltas.

### V2.5 — Finanzas

- `BankReconciliation` ✅ **COMPLETA (3/3)**: C1 `bank-account-ledger` ✅ (2026-06-27, PR #243) → C2 `bank-payment-routing` ✅ (2026-07-02, PR #249) → **C3 `bank-reconciliation` ✅ (2026-07-02, PRs #252/#253 — import de extracto + sesiones FSM + matching + cierre con diferencia; ver "Post-roadmap V2.x")**. C3 nació con modelo V3 aplicado: FSM open→closed terminal, motivo obligatorio (RN-A5) y fechas locales (RN-D5)
- `JournalEntry` ✅ V1 entregado (`journal-entry-outbox`, 2026-06-27 — ver "Post-roadmap V2.x"): partida doble generada async vía Consumer 3 del outbox para ventas/compras/pagos/NC. Falta: plan de cuentas configurable + UI, gastos/cierre de caja, export contable (V2.6)
- `CostCenter` ✅ dimensión + catálogo entregados (`cost-center-dimension`, 2026-06-27 — ver "Post-roadmap V2.x"): catálogo plano `cost_centers` + columna `cost_center_id` en gastos/compras + CRUD y selector opcional. Falta: reporting/agregación por centro (llega con `JournalEntry`/reporting)
- Percepciones y retenciones (cálculo automático en `FiscalDocument` para el mercado argentino) — **depende de `v3-snapshot-pattern`**: sin `FiscalIdentitySnapshot` completo del receptor, la percepción calculada no puede justificarse contra la condición fiscal vigente al momento de emisión
- **Del modelo V3 (§11) entran en esta fase**: `v3-notifications-realtime` (§3, el outbox ya está maduro) y `v3-reporting-invariants` (§8) — ver "Roadmap Modelo V3" abajo

### V3 — Inteligencia

- `AIAgent` configurable (nace aquí una vez que tenga invariantes de negocio reales — ver DEC-21)
- `KnowledgeBase`/`Embedding` con datos propios del tenant (requiere presupuesto para vector DB)
- Automatizaciones trigger-based (alertas de stock, resumen mensual proactivo, predicción de demanda) — los triggers consumen del outbox; la infraestructura de aviso llega antes con `v3-notifications-realtime`
- **Del modelo V3 (§11)**: `v3-product-composition` (BOM ligera de 1 nivel — combos, canastas, elaborados; §7.2) y conversión de unidades del mismo tipo (§7.1, V3.5; el `type` de `units_of_measure` se persiste antes, en `v3-catalog-masters`)

---

## Tabla Resumen

| ID | Nombre | Fase | Governance | Dependencias | Estado |
|----|--------|------|------------|--------------|--------|
| C-01 | billing-schema-migration | 1 — Billing | CRITICO | — | `[x]` |
| C-02 | plan-gating-engine | 1 — Billing | CRITICO | C-01 | `[x]` |
| C-03 | grace-period-logic | 1 — Billing | ALTO | C-02 | `[x]` |
| C-04 | ai-usage-counters-split | 2 — IA | ALTO | C-02 | `[x]` |
| C-05 | multi-user-tenant-architecture | 3 — Multi-tenant | CRITICO | C-02 | `[x]` |
| C-06 | roles-internos-basicos | 3 — Multi-tenant | ALTO | C-05 | `[x]` |
| C-07 | sucursales-module-pro | 3 — Multi-tenant | MEDIO | C-05 | `[x]` |
| C-08 | stock-multisucursal | 3 — Multi-tenant | ALTO | C-07 | `[x]` |
| C-09 | community-bug-fixes | 1 — Billing | MEDIO | — | `[x]` |
| C-10 | subscription-ui-upgrade-flow | 4 — Upgrade | CRITICO | C-03 | `[x]` |
| C-11 | ai-insights-rentabilidad-producto | 2 — IA | MEDIO | C-02, C-04 | `[x]` |
| C-12 | ai-comparative-reports | 2 — IA | MEDIO | C-02, C-04 | `[x]` |
| C-13 | ai-price-suggestion | 2 — IA | MEDIO | C-11 | `[x]` |
| C-14 | export-module | 4 — Upgrade | MEDIO | C-02 | `[x]` |
| C-15 | backend-data-layer | 5 — Migración Python | ALTO | — (scaffold archivado) | `[x]` |
| C-16 | backend-data-api-migration | 5 — Migración Python | ALTO | C-15 | `[x]` |
| C-17 | backend-payments-migration | 5 — Migración Python | CRITICO | C-16 | `[x]` |
| C-18 | frontend-decouple-datacontext | 5 — Migración Python | MEDIO | C-16 | `[x]` |
| C-19 | v20-tenancy-cleanup | 6 — V2.0 Retirada deuda | CRITICO | — | `[x]` |
| C-20 | v20-sale-items-migration | 6 — V2.0 Retirada deuda | ALTO | C-19 | `[x]` (Grupo 10 diferido) |
| C-21 | v20-inventory-unification | 6 — V2.0 Retirada deuda | CRITICO | C-19 | `[x]` |
| C-22 | v20-fiscal-identity-clients | 6 — V2.0 Retirada deuda | BAJO | — | `[x]` |
| C-23 | v20-community-schema-split | 6 — V2.0 Retirada deuda | MEDIO | — | `[x]` |
| C-24 | v20-insights-unification | 6 — V2.0 Retirada deuda | BAJO | C-19 | `[x]` |
| C-25 | v20-outbox-activation | 6 — V2.0 Retirada deuda | MEDIO | C-19 | `[x]` |
| C-26 | v21-branch-as-root | 7 — V2.1 Operación | ALTO | C-21 | `[x]` |
| C-27 | v21-fiscal-profile | 7 — V2.1 Operación | CRITICO | C-22, C-26 | `[x]` |
| C-28 | v21-cash-session | 7 — V2.1 Operación | MEDIO | C-26 | `[x]` |
| C-29 | v21-quote-salesorder | 7 — V2.1 Operación | MEDIO | C-20, C-26 | `[x]` |
| C-30 | v21-customer-supplier-accounts | 7 — V2.1 Operación | MEDIO | C-29 | `[x]` |

---

## Estado del Roadmap V2 — COMPLETO

**Fase 6: 7/7 completados ✅** — C-19 (2026-06-09), C-20/C-22/C-23 (2026-06-10), C-21 (2026-06-12), C-24 (2026-06-13), **C-25 (2026-06-18)** archivados.
**Fase 7: 5/5 completados ✅** — C-26 (2026-06-12), C-27 (2026-06-12), C-28 (2026-06-17), C-29 (2026-06-17), **C-30 (2026-06-20)** archivados.

### 🎉 Roadmap V2 completo — C-30 `v21-customer-supplier-accounts` recién archivado

**C-30** `v21-customer-supplier-accounts` ✅ (2026-06-20, archivado `2026-06-20-v21-customer-supplier-accounts`, PR #199) — `CustomerAccount` / `SupplierAccount` con ledger append-only; `rpc_register_payment_received` / `rpc_register_payment_made` idempotentes; integración con `SalesOrder.confirm()` (`payment_method='credit'` en la misma transacción); specs `customer-account` (nueva) + `supplier-account` (nueva) + `sales-order` (credit añadido) sincronizadas. Migraciones `20260720000001` + `20260720000002` LIVE en prod; 7/7 smoke cases OK.

**Recién archivado (anterior):**
- **C-29** `v21-quote-salesorder` ✅ (2026-06-17, archivado `2026-06-17-v21-quote-salesorder`, PRs #193 + #194) — `Quote`/`SalesOrder` + `quickSale()` POS; hot path transaccional con `branch_stock` + `cash_movement` + outbox + retrocompat `sales`/`sale_items`; 278 tests pasando; 44 tests nuevos (TDD RED→GREEN→TRIANGULATE→REFACTOR completo); migraciones `20260702000001` + `20260702000002` (hotfix: `events.company_id`/`entity_type` nullable para prod drift — C-25 reconcilia). Smoke 4/4 OK.
- **C-25** `v20-outbox-activation` ✅ (2026-06-18, archivado `2026-06-18-v20-outbox-activation`) — Transactional outbox V2.0: `AuditLog` (consumer mandatorio, append-only) + `EmailNotification` (sale_created/stock_adjusted/plan_changed) + consumers idempotentes vía `(event_id, consumer_type)` + relay pure-SQL `rpc_process_outbox_dispatch` via pg_cron (sin `service_role`). Schema reconciliation migration (`events`: canonical V2 columns, legacy nullable, partial index). Producers `PurchaseCreated`/`StockAdjusted` same-tx. Backend 218+ tests (TDD RED→GREEN→TRIANGULATE→REFACTOR), migrations idempotentes. Specs `transactional-outbox` sincronizada. Nota: reconcilia drift de `public.events` de C-29 hotfix (company_id/entity_type now nullable).

**Pendiente externo (no bloquea):**
- **C-27 task 5.2** — Verificacion E2E en homologacion ARCA (WSAA ticket → WSFEv1 CAE): pendiente del tramite AFIP del PO (certificado de homologacion). El adaptador `WSFEAdapter` esta implementado y testeado con SOAP mockeado.
- **v22 task 9.1** — E2E homologacion del modelo de delegacion (facturar por un CUIT representado con el cert de plataforma): mismo gate externo del PO (tramite ARCA). El codigo del modelo de delegacion ya esta en prod y con regresion verde; ver "Post-roadmap V2.x" abajo.

**Diferido:**
- **C-20 Grupo 10** — DROP del header plano (`sales.product_id`, etc.) — bloqueado por representación de líneas de servicio. Será un change propio tras aprobación PO.
- **Vista de presupuestos UI** — pantalla de listado/gestión de presupuestos; diferida del C-29 apply. Candidata para change propio en Fases Futuras.

**Próximo trabajo:** `v3-reporting-invariants` (después de snapshots, RN-D2) del Modelo V3 — `v3-snapshot-pattern` ✅ 2026-07-02, `v3-document-status-history` ✅ 2026-07-03, `v3-notifications-realtime` ✅ 2026-07-04 (PR #262), `v3-soft-delete-policy` ✅ 2026-07-06, `v3-provisioning-seed` ✅ 2026-07-06 (PR #279), `v3-catalog-masters` ✅ 2026-07-06 (PR #282). Después: `v3-api-standards`, percepciones (V2.5), V2.6 contable, V3 Inteligencia, `v3-rbac-multirole` (análisis-sign-off PO).

---

## Post-roadmap V2.x (changes no numerados, post C-30)

> Trabajo dirigido por el PO tras cerrar el roadmap numerado C-01→C-30. No llevan código `C-NN`; viven en `openspec/changes/archive/` con nombre propio. Se listan acá para que CHANGES.md refleje el estado real del repo.

### `cost-center-dimension` — Centro de costo (🎉 abre Fase V2.5 Finanzas)
- **Estado**: `[x]` archivado 2026-06-27 (`2026-06-27-cost-center-dimension`, PR #238). Migración `20260802000001` aplicada por CI al mergear.
- **Governance**: BAJO (catálogo CRUD + columna nullable aditiva; no toca dinero, hot path de venta ni fiscal).
- **Scope**: dimensión analítica opcional `cost_center_id` (modelo de dominio V2 §3.5). Catálogo plano `cost_centers` (account-scoped, RLS lectura=miembros / escritura=owner+admin vía `is_account_writer`, `UNIQUE(account_id, lower(name))`, soft-delete `is_active`); columna nullable `cost_center_id` en `expenses` y `purchases` (`ON DELETE SET NULL`, sin backfill); `rpc_create_purchase_operation` gana `p_cost_center_id` opcional y lo propaga a todas las líneas de la operación. Backend FastAPI 3 capas (`/cost-centers` CRUD, guard owner/admin) + frontend (catálogo + selector opcional en alta de gasto/compra). 44 tests backend + 18 frontend nuevos (TDD RED→GREEN→TRIANGULATE).
- **Por qué ahora**: de-riskea el próximo change pesado `journal-entry-outbox` (su `JournalLine` referencia `cost_center`) metiendo la columna con volumen bajo, evitando la migración dolorosa que el modelo §3.5 advierte.
- **Spec sincronizada**: `cost-center` (nueva).
- **Diferido (fuera de scope)**: jerarquías, distribución porcentual, reporting/agregación por centro (llega con `journal-entry-outbox`/reporting), imputación en ventas (el centro de costo es para costos, no ingresos).
- **Leer antes**: `modelo-dominio-aliadata-v2.md` §3.5, `knowledge-base/05_reglas_de_negocio.md`.

### `journal-entry-outbox` — Contabilidad partida doble vía outbox (V2.5 #2)
- **Estado**: `[x]` archivado 2026-06-27 (`2026-06-27-journal-entry-outbox`, PR #240). Migraciones `20260803000001/02/03` aplicadas por CI (deploy success); verificado en prod read-only (tablas + RLS + relay + 1 solo overload de `rpc_create_purchase_operation`).
- **Governance**: ALTA (registros contables que usa el contador). Diseño firmado por el PO antes del apply.
- **Scope**: `JournalEntry`/`JournalLine` (partida doble) generados **async** desde documentos ya commiteados, vía un **Consumer 3 nuevo en el relay del outbox C-25** (`rpc_process_outbox_dispatch`, SQL puro, sin service_role/HTTP). 5 eventos V1: `SaleConfirmed`, `PurchaseCreated`, `PaymentReceived`, `PaymentMade`, `CreditNoteIssued`. Plan de cuentas ~10 códigos AR hardcodeados (`account_code TEXT`, sin FK). IVA discriminado en A/B (neto 4100 + IVA DF 4200); Factura C single-line. Idempotencia `UNIQUE(source_event_id)`; balance Σdebe=Σhaber como ASSERT (P0450) con retry. `cost_center_id` propagado desde la compra. NC = asiento espejo (reversal). 2 producers nuevos creados (`PurchaseCreated` —hueco real de C-25— y `CreditNoteIssued`/`rpc_issue_credit_note`). `GET /journal-entries` read-only. 84 tests nuevos (suite outbox 126/126).
- **Decisiones (PO + técnicas)**: plan de cuentas hardcodeado (tabla+UI → V2.6); scope ventas+compras+pagos+NC (gastos/caja → V2.6); consumer SQL puro; disparador venta = `SaleConfirmed` (no FiscalDocumentIssued, p/ monotributista); discriminar IVA.
- **Fix en el camino**: bug latente de overload de `rpc_create_purchase_operation` (C-21 lo revirtió a 4 args → cost-center dejó 2 overloads; `42725`). Colapsado a 1 canónico vía DO-block + COMMENT con firma. Ver engram `opsx/journal-entry-outbox/apply`.
- **Diferido (V2.6)**: plan de cuentas configurable + UI, asientos de gastos/`CashSessionClosed`/`StockAdjusted`, export a Tango/Bejerman/Colppy.
- **Specs sincronizadas**: `journal-entry` (nueva), `transactional-outbox` (Consumer 3).
- **Leer antes**: `modelo-dominio-aliadata-v2.md` §5.6/§5.8/§5.9, `openspec/explore/2026-06-27-journal-entry-outbox.md`, `knowledge-base/05_reglas_de_negocio.md`.

### `bank-account-ledger` — Ledger bancario, carga manual (V2.5 #3 · BankReconciliation C1/3)
- **Estado**: `[x]` archivado 2026-06-27 (`2026-06-27-bank-account-ledger`, PR #243). Migración `20260804000002_bank_account_ledger.sql` aplicada por CI al mergear.
- **Specs sincronizadas**: `bank-account` (nueva), `bank-movement` (nueva).
- **Governance**: MEDIO (tablas aisladas nuevas + RPCs manuales; no toca el hot path de venta/pago ni dinero real existente).
- **Secuencia**: **C1 de 3** de BankReconciliation → C1 `bank-account-ledger` → C2 `bank-payment-routing` → C3 `bank-reconciliation`. C1 entrega un dominio bancario **autónomo, carga manual únicamente**, + costuras documentadas (no construidas) para C2/C3.
- **Scope**: `bank_accounts` (root **org-level**, tenancy directa por `account_id` — NO branch-scoped como las cajas; `cbu` 22 dígitos validado, `alias`, `currency`, `opening_balance`, `is_active`) + `bank_movements` (ledger append-only espejo de `cash_movements`: `amount` con signo, `balance_after`, `value_date`, `branch_id` nullable analítica; CHECK con el **enum completo ya fijado** `transfer_in/transfer_out/card_settlement/fee/tax_debit/interest/manual_adjustment`). Helper intra-tx `_register_bank_movement` (**contrato C1→C2**, espejo de `c28_register_cash_movement`, REVOKE de PUBLIC). RPCs SECURITY DEFINER `rpc_create_bank_account`/`rpc_update_bank_account`/`rpc_register_bank_movement` (carga manual — solo acepta `transfer_in/transfer_out/manual_adjustment`, rechaza los reservados). RLS: SELECT por `account_id` (denormalizado en `bank_movements`, sin subquery por fila — patrón `journal_lines` D7); escritura solo vía RPC. Migración `20260804000002_bank_account_ledger.sql`. ERRCODEs P0401/P0410/P0411/P0412.
- **Principio**: dos ledgers sincronizados por el outbox — `bank_movements` = OPERACIONAL (base de la conciliación C3); `1110 Banco` = espejo CONTABLE alimentado async por C2. **C1 NO postea al journal** (`1110` sigue reservado y vacío) — eso es C2.
- **Greenfield**: no existe ninguna tabla `bank_*`; la regla "ninguna feature nueva sobre tablas en retirada" (RN-97) NO aplica.
- **Diferido (C2/C3)**: captura de `payment_method`, ruteo automático al banco, posteo a `1110`, reinterpretar `payment_method='other'` (C2); import de extracto CSV/Excel, matching, `reconciliation_sessions`, columnas aditivas `statement_line_id`/`reconciliation_status`/`reconciled_at` (C3). Modelado de `card_settlement` bruto≠neto y DV del CBU también diferidos.
- **Leer antes**: `modelo-dominio-aliadata-v2.md` §3.5 + diagrama de clases (`BankAccount`/`ReconciliationSession`), `supabase/migrations/20260701000001_c28_cash_session.sql` (espejo), `knowledge-base/05_reglas_de_negocio.md`.

### `bank-payment-routing` — Ruteo de pagos al banco + posteo 1110 (V2.5 C2 · BankReconciliation C2/3)
- **Estado**: `[x]` archivado 2026-07-02 (`2026-07-02-bank-payment-routing`, PR #249). Migración `20260804000007_bank_payment_routing.sql` aplicada en prod (verificado: RPC firma de 6 args live, `_journal_post_from_event` rutea a `1110`).
- **Governance**: ALTA (rutea dinero real de pagos/cobros al ledger bancario y al journal contable). Diseño firmado por el PO antes del apply.
- **Secuencia**: **C2 de 3** de BankReconciliation → C1 `bank-account-ledger` ✅ → C2 `bank-payment-routing` ✅ → C3 `bank-reconciliation` (próximo).
- **Scope**: `rpc_register_payment_received`/`rpc_register_payment_made` ganan `p_payment_method`/`p_bank_account_id` (aditivos, default retrocompatible `cash`/`NULL`); un método bancario (`transfer`/`card`/`check`) escribe un `bank_movement` intra-tx vía el helper `_register_bank_movement` (contrato C1→C2) y exige `p_bank_account_id` válido/activo (`P0400`/`P0412`). El evento de outbox (`PaymentReceived`/`PaymentMade`) lleva `payment_method` en el payload; el Consumer 3 (`_journal_post_from_event`) lo lee y rutea la contrapartida contable a `1110 Banco` (antes reservada y vacía) vs `1100 Caja`. `SaleConfirmed` también rutea: `sales_orders.payment_method` CHECK ampliado a `{cash, transfer, card, other, credit}`; transfer/card → `1110` async (journal-only, sin `bank_movement` operacional del lado de venta).
- **Decisiones (OQ-1..5, PO sign-off 2026-07-01)**: OQ-1 cuenta bancaria por **parámetro explícito** (`p_bank_account_id`, la UI elige, sin default por org); OQ-2 taxonomía `{cash, transfer, card, check}` con **card incluido y bruto** (fee/tax netting → C3); OQ-3 enum de ventas ampliado con `transfer`/`card`, `other` sigue mapeando a `1100`; OQ-4 ruteo del lado de venta es **journal-only** (sin `bank_movement` operacional, `_c29_confirm_order_core` no se toca más allá del CHECK); OQ-5 **sin backfill** (pagos históricos quedan como cash, default retrocompatible).
- **Specs sincronizadas**: `bank-movement` (ADDED + MODIFIED), `customer-account` (MODIFIED), `supplier-account` (MODIFIED), `journal-entry` (MODIFIED).
- **Leer antes**: `openspec/changes/archive/2026-07-02-bank-payment-routing/design.md` (D1-D6 + OQ-1..5), `openspec/changes/archive/2026-06-27-bank-account-ledger/` (contrato C1→C2), `knowledge-base/05_reglas_de_negocio.md`.

### `bank-reconciliation` — Conciliación bancaria vs extracto (V2.5 C3 · BankReconciliation C3/3, cierra la secuencia)
- **Estado**: `[x]` archivado 2026-07-02 (`2026-07-02-bank-reconciliation`, PRs #252 feature + #253 fix deploy). Migración `20260805000001_bank_reconciliation.sql` aplicada en prod (verificado read-only + smoke transaccional con rollback: fee manual → P0410 card_settlement → import → open → match → undo → re-match → close P0431/dif=77 — cero rastros).
- **Governance**: MEDIO (greenfield sobre el ledger existente; no toca dinero en vuelo, hot path ni journal).
- **Scope**: `bank_statement_imports`/`bank_statement_lines` (extracto crudo **inmutable**, filas normalizadas jsonb — parseo CSV en el cliente, dedupe por `file_hash`, cap 5000, idempotencia `bank_statement_import`); `reconciliation_sessions` con FSM `open→closed` **terminal** (anti doble-apertura UNIQUE parcial P0409; cierre calcula `difference` con corte por `value_date` RN-D5; diferencia ≠ 0 exige motivo P0431 RN-A5); `reconciliation_matches` como grafo con `match_group` (1:1/1:N/N:1, Σ montos validada P0433, anti doble-match UNIQUE parcial + P0434, **undo con motivo sin borrar**); `bank_movements.reconciliation_status`/`reconciled_at` denormalizados (solo los tocan las RPCs de match); `rpc_register_bank_movement` ampliada a `fee`/`tax_debit`/`interest` ("solo anotar" V1, decisión PO — `card_settlement` sigue reservado). Backend 3 capas + endpoint manual REST (C1 no tenía wiring) + fix gap `errors.py` (P0410/P0411/P0412 caían en 500). Frontend `/finanzas/conciliacion` (parser es-AR + SHA-256, panel doble, sugerencias 1:1 ±3 días, cierre con motivo, "Anotar"). **La conciliación NUNCA toca el journal** (gate negativo). 42 tests backend (suite 810) + 13 frontend (suite 410).
- **Incidente de deploy (lección/REGLA)**: el primer `db push` falló con 23514 — el DROP+ADD del CHECK de `operation_idempotency.operation_kind` omitía `event_consumer` (hotfix outbox `20260804000005`, con filas en prod); CI no lo atrapa porque su DB nace vacía. **REGLA: al recrear ese CHECK, enumerar la UNIÓN vigente en prod (verificar `pg_get_constraintdef`), no solo los kinds que el change conoce.** Fix transaccional-seguro editando la migración no registrada (#253) + test de regresión.
- **Specs sincronizadas**: `bank-reconciliation` (nueva), `bank-movement` (MODIFIED taxonomía + RPC manual; ADDED estado de conciliación).
- **Diferido (fast-follow)**: auto-generación de asientos de ajuste, netting de `card_settlement` (bruto≠neto), sugerencias IA, presets de mapeo CSV por banco, XLSX nativo.
- **Leer antes**: `openspec/changes/archive/2026-07-02-bank-reconciliation/design.md` (D1-D9), specs `bank-reconciliation`/`bank-movement`.

### `v22-afip-delegation-billing` — Facturación AFIP por delegación
- **Estado**: `[x]` archivado 2026-06-26. Código ya en prod; gate externo del PO = **task 9.1** (E2E homologación ARCA, ver "Pendiente externo" arriba).
- **Governance**: CRÍTICO (fiscal — la clave privada del cert de plataforma es el secreto más sensible del sistema).
- **Scope**: migración del modelo **cert-por-usuario → delegación** (como Xubio/Facturante/TusFacturas). La plataforma tiene **un único** certificado representante y factura por cuenta de cada usuario; el usuario sólo autoriza a EmprendeSmart en ARCA (Administrador de Relaciones → "Facturación Electrónica") y atestigua el flag `delegacion_autorizada`.
  - `WSFEAdapter` autentica SIEMPRE con el cert de plataforma; `Auth.Cuit` = CUIT del emisor/representado por comprobante.
  - Factory `build_cae_adapter`: gate "¿cert de plataforma configurado?" (no per-account); `WSFEStubAdapter` sigue siendo el default seguro.
  - Caché del TA WSAA keyada por `(representante + ambiente)` — ~1 TA por ambiente compartido entre CUIT.
  - Deprecados los endpoints de upload de cert por usuario (`POST /fiscal/profile/cert-upload-url`, `PUT /fiscal/profile/cert-path`).
  - UI: se reemplaza la sección de upload por la guía de delegación ARCA en `FiscalSettings.tsx`.
- **Specs sincronizadas**: `afip-platform-credential` (nueva), `afip-fiscal-document` (modificada), `fiscal-profile` (modificada + deprecaciones).
- **OQ-5 (botón "Enviar al ARCA" en la venta)**: salió como change propio → `facturar-venta-afip` (abajo).
- **Leer antes**: `knowledge-base/05_reglas_de_negocio.md` (dominio fiscal), engram `opsx/v22-afip-delegation-billing/*`.

### Otros changes post-roadmap (archivados)
- **`c29-write-sale-items`** ✅ (2026-06-22, PRs #203/#204) — el hot path de C-29 escribe `sale_items` (migración `20260721000001`) + backfill de ventas legacy; primer paso hacia el desbloqueo de C-20 Grupo 10.
- **`fix-delete-stock-restore`** ✅ (2026-06-22, PR #201) — el borrado de una venta repone el stock decrementado (bug de borrado-sin-reponer).
- **`v21-wsfe-homologacion-wiring`** ✅ (2026-06-23, PRs #205/#207) — wiring WSAA→WSFEv1 contra homologación ARCA; CAE real de homologación obtenido (cierra C-27 task 5.2).
- **`v21-wsfe-production-hardening`** ✅ (2026-06-23, PRs #208/#209) — los 5 gaps de producción del WSFE: `CondicionIVAReceptorId` (RG 5616), array `Iva`, numeración vía `FECompUltimoAutorizado`, caching del TA en Postgres, supabase-py.
- **`idle-session-timeout`** + **`idle-session-server-enforcement`** ✅ (2026-06-24) — cierre de sesión por inactividad (cliente + enforcement server-side).
- **`facturar-venta-afip`** ✅ (2026-06-26, PRs #228/#229) — emitir factura AFIP desde la venta (MVP Factura C). Era la OQ-5 de v22.
- **`fiscal-receptor-iva-relay`** ✅ (2026-06-26, PRs #226/#227) — propaga la identificación del receptor (`DocTipo`/`DocNro`) + desglose de IVA a través del relay del CAE.
- **`register-name-terms-captcha`** ✅ (2026-06-27, PRs #231–#235) — alta con nombre+apellido, consentimiento legal + opt-in email, captcha Turnstile en toda la auth; + provincia, mail al admin y validación de formato de email/teléfono.
- **`facturar-venta-manual`** ✅ (2026-06-27, PR #242) — promoción lazy de una venta legacy de `/ventas` a `SalesOrder` facturable (`rpc_promote_legacy_sale_to_order`, side-effect-free) + botón "Facturar"; cierra la asimetría con el flujo AFIP.
- **`bank-account-crud`** ✅ (2026-07-04, PR #272) — alta de cuentas bancarias: `POST /bank-accounts` (3 capas, sin migraciones — reusa `rpc_create_bank_account`) + `BankAccountFormDialog` (RHF+Zod) accesible desde el empty state y el header de `/finanzas/conciliacion` + rename del ítem de sidebar "Conciliación bancaria"→"Bancos"; cierra el gap de UI de alta que `bank-account-ledger` (C1) había dejado. Spec sincronizada: `bank-account` (MODIFIED).

---

## Roadmap Modelo V3 (2026-07-02) — changes derivados de `modelo-dominio-aliadata-v3.md`

> El PO adoptó el **modelo de dominio V3** (`modelo-dominio-aliadata-v3.md`, 2026-07-02): extensión del V2 con patrones extraídos de la spec Food Store — **no reemplaza al V2, lo extiende**. El V3 §11 asignaba sus deltas a fases V2.0/V2.1 que ya cerraron, así que esos ítems entran como **retrofit** sobre el schema vivo. Los changes de esta sección no llevan código `C-NN` (convención post-roadmap). Gap-analysis verificado contra el código el 2026-07-02.

### Gap-analysis (modelo V3 vs. código en prod)

| V3 § | Patrón | Estado verificado en código | Change |
|---|---|---|---|
| §1 | Snapshot Pattern | ✅ Columnas snapshot congeladas en líneas (`name`, `sku`, `unit_cost`, `iva_rate`) + `stock_movements.unit_cost_snapshot` + `FiscalIdentitySnapshot` del receptor (`receptor_legal_name`, `receptor_iva_condition`). **Desbloquea C-20 Grupo 10** (línea de servicio = `product_id NULL` + `name_snapshot`). Archivada 2026-07-02. | ✅ `v3-snapshot-pattern` |
| §2 | FSM + historial de estados | ✅ Tabla append-only `document_status_history`, catálogo `document_status_transitions` con política como datos, `record_status_transition` helper, `allowed_role` permisivo (inerte hoy, activado por RBAC). Archivada 2026-07-03. Desbloquea matriz rol×transición de RBAC. | ✅ `v3-document-status-history` |
| §3 | Notificación post-commit | ✅ Consumer 4 (`_notification_from_event` idempotente) + tabla `notifications` read-model RLS-guarded + hook Realtime `useNotifications` + 5 producers (CashSessionClosed, StockBelowMinimum, QuoteAccepted, TransferDispatched, FiscalDocumentRejected). Archivada 2026-07-04. Desbloquea UI realtime. | ✅ `v3-notifications-realtime` |
| §4 | Soft delete uniforme | ✅ `deleted_at`/`deleted_by` en 6 maestros (`clients`, `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`); índices únicos parciales RN-B3; guard RN-B4 (trigger en `products`: rechaza borrado con stock ≠ 0 o referencia en documentos `draft`); `BaseRepository.soft_delete()` centralizado; `is_active` conservado en paralelo (no se dropea). `branches` queda fuera de scope (V3 §4: se desactiva, no se borra); `categories`/`price_lists` no existen como tablas. Archivada 2026-07-06. | ✅ `v3-soft-delete-policy` |
| §5 | RBAC multi-rol | ❌ `account_members.role` singular, CHECK `('owner','admin','member')`; sin `assigned_by`/`expires_at`, sin roles funcionales (SELLER/CASHIER/STOCK/…) | `v3-rbac-multirole` |
| §6 | UoW + capas | ⚠️ Layering routers→services→repositories ya existe; la transaccionalidad del hot path vive en **RPCs SQL `SECURITY DEFINER`** (equivalente funcional del UoW — decisión a registrar, no a "corregir"). Falta: `BaseRepository` con soft-delete/paginación, RFC 7807 uniforme | `v3-api-standards` |
| §6.3 | Idempotencia | ✅ `operation_idempotency` + dedupe de consumers `(event_id, consumer_type)` ya existen. Falta solo generalizar `Idempotency-Key` del cliente | `v3-api-standards` |
| §7.1 | UnidadMedida tipada | ✅ Formalizado como contrato: `type` (`unit\|weight\|volume\|length\|custom`) ya era `NOT NULL` + `CHECK` en prod (10 unidades del sistema tipadas), catálogo mixto global (`is_system`)/per-tenant (`account_id`). Spec-only, cero DDL. Archivada 2026-07-06. | ✅ `v3-catalog-masters` |
| §7.2 | Composición de producto (BOM) | ❌ No existe | fase V3 (`v3-product-composition`) |
| §7.3 | Direcciones múltiples | ✅ Tabla `client_addresses` (operativa, distinta de la fiscal): `alias`, `is_primary` con índice único parcial + RPC `rpc_set_primary_client_address` de switch atómico, soft-delete alineado a V3 §4. UI diferida (solo DB + API + tipo TS). Archivada 2026-07-06. | ✅ `v3-catalog-masters` |
| §7.4 | Imágenes de producto | ❌ `products` sin imágenes (solo landing usa Storage) | — (descartado por PO 2026-07-04, no se implementa) |
| §7.5 | Seed de provisioning | ✅ COMPLETADA 2026-07-06 (PR #279): `handle_new_user` siembra eager branch "Casa Central" + cashbox "Caja Principal" (ARS); backfill de las ~29 cuentas existentes. Lista de precios/formas de pago/plan de cuentas quedan OUT (estructuras no existentes — ver nota en la sección del change) | `v3-provisioning-seed` ✅ |
| §8 | Invariantes reporting RN-D | ⚠️ Parcial: timezone fix del dashboard ✅ (RN-D5), DECIMAL ✅ (RN-D4); sin enforcement de cancelados/NC (RN-D1), snapshots (RN-D2) ni devengado-vs-percibido (RN-D3) | `v3-reporting-invariants` |
| §9 | Endurecimiento plataforma | ⚠️ Captcha ✅, firma de webhooks ✅ (C-17), fixtures por rol ✅ (conftest); rate limiting/refresh token = config de Supabase Auth (tarea PO, no change) | — |
| §10 | Rechazos explícitos | ✅ Ya alineados: `branch_stock` único ledger (C-21), rol en membership (C-05), Supabase Realtime (DEC-16), Postgres real en CI (validate-kpis) | — (decisiones registradas) |

### Secuencia recomendada

```
C3 bank-reconciliation ✅ (2026-07-02 — nació con RN-A/RN-D5 aplicadas)
  → v3-snapshot-pattern ✅ (2026-07-02, PR #255 — DESBLOQUEÓ C-20 Grupo 10)
  → v3-document-status-history ✅ (2026-07-03, PRs #258/#259 — FSM + historial, RBAC-ready)
  → v3-notifications-realtime ✅ (2026-07-04, PRs #262/#264 — Consumer 4 + campana Realtime + specs synced)
  → v3-soft-delete-policy ✅ (2026-07-06, PRs #275/#276/#277)
  → v3-provisioning-seed ✅ (2026-07-06, PR #279)
  → v3-catalog-masters ✅ (2026-07-06, PR #282 — UoM tipada spec-only + client_addresses)
  → v3-reporting-invariants ⭐ SIGUIENTE   (después de snapshots, RN-D2)
  → v3-api-standards                 (transversal, cualquier momento)
  → v3-rbac-multirole                (CRÍTICO — análisis + sign-off PO antes de escribir; consume allowed_role de v3-document-status-history)
  → percepciones-retenciones         (V2.5, después del snapshot fiscal)
```

---

### `v3-snapshot-pattern` — Inmutabilidad histórica de documentos (V3 §1) ⭐
- **Estado**: `[x]` ✅ completada 2026-07-02 (PR #255)
- **Governance**: ALTO (toca los RPCs del hot path de venta/compra; cambios aditivos, sin drops)
- **Scope**:
  - Columnas snapshot en `sale_items`, `purchase_items`, `quote_items`, `sales_order_items`: `name_snapshot TEXT`, `sku_snapshot TEXT`, `unit_cost_snapshot NUMERIC(15,2)`, `iva_rate_snapshot NUMERIC(5,2)`
  - Los RPCs de escritura (`rpc_create_sale_operation` v2, `rpc_create_purchase_operation`, `_c29_confirm_order_core`, RPCs de quotes) congelan los snapshots desde el maestro **en la misma transacción**
  - `stock_movements.unit_cost_snapshot` para valuación de inventario (V3 §1: el ledger ya congela `balance_after`; se agrega el costo)
  - `fiscal_documents`: completar el `FiscalIdentitySnapshot` del receptor — `receptor_legal_name`, `receptor_iva_condition` (hoy solo doc tipo/nro) + datos del emisor vigentes al emitir
  - Nueva regla de negocio en `knowledge-base/05`: **tras `confirm()` las líneas no se editan** — corrección = documento nuevo (NC, ajuste), nunca UPDATE (equivalente RN-04 Food Store)
  - Backfill best-effort de líneas históricas desde el maestro actual, marcadas `snapshot_backfilled = true` (reportes distinguen dato exacto vs. aproximado)
  - Reporting de margen (`rpc_product_profitability`, KPIs de dashboard) migra a leer snapshots (RN-D2)
- **Desbloquea**: **C-20 Grupo 10** (DROP del header plano) — la línea de servicio pasa a representarse como ítem con `product_id NULL` + `name_snapshot`, que era exactamente el bloqueo registrado
- **Dependencias**: ninguna (aditivo)
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §1 y §8, `modelo-dominio-aliadata-v2.md` §5.3, `knowledge-base/05_reglas_de_negocio.md`

### `v3-document-status-history` — FSM + historial de estados append-only (V3 §2)
- **Estado**: `[x]` ✅ completada 2026-07-03 (PRs #258 squash `9adf785`, #259 `fcdb32c`)
- **Governance**: MEDIO (tabla nueva + RPC de historial; cambios aditivos a otros RPCs)
- **Scope**: ✅ Implementado
  - Tabla `document_status_history` genérica append-only: `(id, account_id, document_type, document_id, from_status, to_status, performed_by, reason, occurred_at)`; RLS sin UPDATE/DELETE (RN-A3 enforzado con grants + REVOKE)
  - RN-A1: toda transición de Quote/SalesOrder/FiscalDocument/CashSession/ReconciliationSession/StockTransfer inserta historial **en la misma transacción**; RN-A2: creación registra `from_status = NULL`
  - `document_status_transitions` catálogo con datos: transiciones válidas + `is_terminal_to`, `requires_reason`, `allowed_role` (permisivo, inerte)
  - Helpers STABLE: `is_valid_transition()`, `is_terminal_status()`, `transition_requires_reason()` accesibles a `authenticated`
  - `record_status_transition()` helper DEFINER: valida transición + exige reason si `requires_reason`, inserta en historial
  - Retrofit: `rpc_accept_quote`, `_c29_confirm_order_core`, `rpc_open_cash_session`, `rpc_close_cash_session`, `rpc_close_reconciliation_session`, `rpc_emit_pending_cae` + relay CAE (backend)
  - UI: componente `DocumentTimeline` (Server Component) renderiza historial ordenado por `occurred_at` en detalles de venta/presupuesto/factura
  - RN-A4 (dimensión por rol) estructurada vía `allowed_role` pero inerte; se activa con `v3-rbac-multirole`
- **Dependencias**: ninguna
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §2, `knowledge-base/05_reglas_de_negocio.md` (RN-A1..A5), migraciones anteriores a `20260807000001` (FSMs en CHECKs, catálogo seed)
- **PRs**: #258 (Squash apply completo + tests + gates), #259 (post-apply follow-up), migración `20260807000001` aplicada prod + smoke OK

### `v3-notifications-realtime` — Notificaciones in-app post-commit (V3 §3)
- **Estado**: `[x]` ✅ completada 2026-07-04 (PR #262 squash `d0c5f26` + PR de cierre)
- **Governance**: MEDIO (consumer nuevo del outbox + tabla read-model; no toca transacciones de negocio)
- **Scope**: ✅ Implementado
  - Tabla `notifications` (read model): `(id, account_id, branch_id, type, severity, payload jsonb, audience uuid[], read, created_at, read_at)`; RLS por audiencia (SELECT/UPDATE con USING+WITH CHECK, sin INSERT policy); índices dropdown + parcial no-leídas; TTL 30 días solo-leídas vía pg_cron
  - **Consumer 4 del relay del outbox** (`rpc_process_outbox_dispatch`, consumers 1-3 preservados byte-a-byte): helper `_notification_from_event` idempotente por `(event_id,'Notification')`; audiencia resuelta server-side en `_notification_audience` (punto único migrable a `v3-rbac-multirole`)
  - Canal Supabase Realtime `postgres_changes` sobre `notifications` (primera suscripción Realtime del frontend) — RLS filtra el stream server-side; hook `useNotifications` (React Query, resync FS §9.6, sin polling) + `NotificationBell` en el header
  - **5 producers nuevos**: `CashSessionClosed` (rpc_close_cash_session), `StockBelowMinimum` (reutiliza trigger `check_branch_low_stock` / `branch_stock.min_stock`), `QuoteAccepted` (rpc_accept_quote, seller=created_by proxy), `TransferDispatched` (rpc_transfer_stock), `FiscalDocumentRejected` (trigger AFTER UPDATE — el rechazo CAE lo persiste el backend Python con service_role, sin RPC)
  - **No confundir con `sale_notifications`** (log de envíos WhatsApp/email al cliente final — otra cosa, no se tocó)
- **Dependencias**: outbox activo ✅ (C-25 + revival 2026-07-01 #248)
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §3, spec `transactional-outbox`, `knowledge-base/09_decisiones_y_supuestos.md` §DEC-16 (Realtime en Supabase)
- **PRs**: #262 (apply completo: migraciones `20260808000001`/`20260808000002` + frontend + 5 tests Vitest), cierre con `20260808000003` (REVOKE advisor). Verificado en prod: publicación Realtime ✅, RLS ✅, smoke Consumer 4 con rollback ✅, advisors sin hallazgos nuevos residuales

### `branch-min-stock-realign` — Realineación de min_stock por sucursal (hallazgo de `v3-notifications-realtime`)
- **Estado**: `[x]` ✅ completada 2026-07-04 (PRs #265 squash `f1fe4e1` + fix `93f9ced`, #266 squash `f43ec3a`)
- **Governance**: MEDIO (RPC nueva + backfill + vista recreada; no toca dinero ni auth)
- **Scope**: RPC `rpc_set_product_min_stock` propaga `products.min_stock` a **todas** las filas `branch_stock` del producto en la misma transacción de creación/edición (wired en `product_repository.create()`/`update()`); backfill idempotente `products→branch_stock` con gate de 0 divergencias; vista `v_products_with_stock` recreada exponiendo `min_stock` derivado de `branch_stock` (no de `products.min_stock`); `products.min_stock` queda **DEPRECATED** (comentario en columna, sin DROP — conservada por el dual-write del importador). Nació de un hallazgo durante `v3-notifications-realtime`: el trigger `check_branch_low_stock` ya leía `branch_stock.min_stock`, pero nada lo poblaba desde el formulario — el umbral quedaba frozen en 0.
- **Specs sincronizadas**: `branch-stock` (2 ADDED: propagación + backfill; 1 MODIFIED: alerta de stock bajo), `inventory-single-ledger` (1 MODIFIED: vista de compatibilidad con `min_stock` derivado).
- **Dependencias**: ninguna (aditivo; DROP de `products.min_stock` diferido a change destructivo posterior)
- **Leer antes**: `knowledge-base/05_reglas_de_negocio.md` (RN-23), `modelo-dominio-aliadata-v3.md` §3 (contexto de `v3-notifications-realtime`)

### `v3-soft-delete-policy` — Política única de borrado (V3 §4)
- **Estado**: `[x]` ✅ completada 2026-07-06 (PRs #275 `58688a2`, #276 `0b1b2a6`, #277 `62f5a15`)
- **Governance**: MEDIO (cambia semántica de borrado de maestros; documentos/ledgers no se tocan)
- **Scope**: ✅ Implementado
  - Política por categoría (V3 §4): maestros → soft delete (`deleted_at` + `deleted_by`); documentos confirmados → jamás se borran, se **anulan** por transición con motivo; ledgers → contra-asiento; drafts → hard delete OK; Membership se revoca, UserAccount se anonimiza
  - `deleted_at`/`deleted_by` agregados a los 6 maestros: `clients` (solo tenía `deleted_at`, sin `deleted_by` — verificado durante propose/apply), `products`, `suppliers`, `cost_centers`, `cashboxes`, `bank_accounts`. `categories`/`price_lists` **no existen como tablas** en el modelo actual (verificado; no había nada que migrar). `branches` queda **fuera de scope** (V3 §4: una sucursal se desactiva, no se borra — `is_active` sigue siendo la política correcta ahí)
  - RN-B3: índices únicos parciales (`WHERE deleted_at IS NULL`) para recrear claves naturales (ej. SKU) previamente borradas
  - RN-B4: trigger en `products` rechaza el soft delete con stock ≠ 0 o referencia activa en documentos `draft`
  - RN-B1/B2 en el backend: `BaseRepository.soft_delete(table, row_id, account_id, deleted_by)` centralizado; filtro `deleted_at IS NULL` no se repite por query concreta
  - `is_active` se conserva en paralelo en las entidades que ya lo tenían (no se dropea; convive con `deleted_at`)
- **Specs sincronizadas**: `soft-delete-policy` (NUEVA capability, 5 Requirements ADDED), `base-repositories` (2 Requirements ADDED: `soft_delete()` + lecturas que excluyen borrados por defecto)
- **Dependencias**: ninguna (sinergia con `v3-api-standards` por `BaseRepository`)
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §4, `modelo-dominio-aliadata-v2.md` §2.6.5 (H-riesgo original), `knowledge-base/04_modelo_de_datos.md`

### `v3-rbac-multirole` — Membership multi-rol con expiración (V3 §5)
- **Estado**: `[ ]` pendiente
- **Governance**: **CRÍTICO** (auth/RLS — solo análisis hasta sign-off explícito del PO)
- **Scope**:
  - Pivot `account_member_roles`: `(member_id, role, assigned_by, assigned_at, expires_at)` reemplaza `account_members.role` singular (verificado: CHECK `('owner','admin','member')`); compat: cada rol legacy se migra a una fila del pivot
  - Catálogo cerrado y global (se ratifica contra Food Store: sin RBAC dinámico por tenant) ampliado: `OWNER / ADMIN / SELLER / CASHIER / STOCK / PURCHASES / ACCOUNTANT / VIEWER`
  - `expires_at` (rol temporal: cajero suplente, contador en época de balance) evaluado en `isActive()` — el enforcement ignora roles vencidos
  - Migrar `require_role` (10+ services del backend) y los helpers RLS (`is_account_writer`, `current_account_ids`) a leer el pivot — con feature flag estilo Strangler Fig
  - Matriz **rol × transición FSM** (RN-A4): `CASHIER` cobra pero no anula; `STOCK` ajusta con motivo pero no confirma compras — enforcement sobre `StatusTransitionPolicy`
  - UI `/organizacion/roles`: asignación multi-rol con quién/cuándo/vencimiento
- **Dependencias**: `v3-document-status-history` (para la matriz por transición); gating por plan a definir con PO (¿roles funcionales solo en avanzado/pro?)
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §5 y §10, `knowledge-base/03_actores_y_roles.md`, migración `20260606010000_roles_internos.sql`

### `v3-provisioning-seed` — Aprovisionamiento completo por tenant (V3 §7.5)
- **Estado**: `[x]` ✅ COMPLETADA 2026-07-06 (PRs #279/#280)
- **Governance**: MEDIO (toca `handle_new_user` — camino de registro)
- **Qué se implementó**: `handle_new_user` siembra EAGER una sucursal default "Casa Central" + caja default "Caja Principal" (ARS) en el mismo paso de provisioning del signup, en sub-bloque `BEGIN...EXCEPTION WHEN OTHERS THEN RAISE WARNING...END` (un fallo del seed degrada, nunca aborta el registro). Backfill idempotente de las ~29 cuentas existentes en la misma migración (`20260812000001_v3_provisioning_seed.sql`, PR #279). PR #280 registra la verificación post-merge en prod (baseline vs. conteos finales).
- **Scoped OUT (verificado contra el código real, no supuesto — ver design.md)**: lista de precios default (la tabla `price_lists` NO existe — crearla es otro change), formas de pago (`EFECTIVO`/`TRANSFERENCIA`/`MERCADOPAGO`/`CTA_CTE` — hoy solo un CHECK de 2 valores `cash|other` en `sales_orders`, sin tabla ni enum — convertirlo en catálogo es un change propio), plan de cuentas mínimo (diferido a V2.6, un test lo prohíbe activamente), unidades de medida (YA provisionadas globalmente vía `is_system=true` + RLS `uom_account_select` desde `20260509211504` — nada per-tenant que seedear).
- **Pendiente (no bloqueante)**: task 3.3 (T3 manual, "<5 minutos para vender") queda a cargo del PO — registrar un usuario real en prod y confirmar que puede abrir caja y hacer una quickSale sin crear branch/caja a mano. Requiere el flujo real de signup (captcha + verificación de email); la verificación DB-level equivalente ya fue hecha (branch+cashbox se crean correctamente vía el trigger real). Ver design.md.
- **Dependencias**: ninguna
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §7.5, `supabase/migrations/20260812000001_v3_provisioning_seed.sql`, `openspec/changes/archive/2026-07-06-v3-provisioning-seed/`, `knowledge-base/07_flujos_principales.md` §Flujo registro

### `v3-reporting-invariants` — Invariantes RN-D en KPIs y proyecciones (V3 §8)
- **Estado**: `[ ]` pendiente
- **Governance**: BAJO-MEDIO (read models; no toca escritura)
- **Scope**:
  - Auditar todos los RPCs de reporting (`rpc_dashboard_kpi_summary`, `rpc_product_profitability`, `rpc_period_comparison`, KPIs admin) contra RN-D1..D5 y corregir desvíos
  - RN-D1: documentos `CANCELED`/anulados jamás suman; notas de crédito **restan**
  - RN-D2: márgenes sobre `unit_price_snapshot`/`unit_cost_snapshot` (requiere `v3-snapshot-pattern`)
  - RN-D3: separar ingresos *percibidos* (cobro registrado / `mp_status = approved`) de *devengados* (facturado no cobrado) — métricas distintas en dashboard
  - RN-D5: todos los filtros de período con fecha local del tenant (el fix de timezone del dashboard 2026-06-08 se generaliza como regla)
- **Dependencias**: `v3-snapshot-pattern` (para RN-D2)
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §8, `knowledge-base/05_reglas_de_negocio.md` §RN-30..34

### `v3-api-standards` — Estándares de plataforma backend (V3 §6)
- **Estado**: `[ ]` pendiente
- **Governance**: BAJO (transversal, sin cambio de comportamiento de negocio)
- **Scope**:
  - Errores RFC 7807 uniformes (`detail`, `code`, `field`) sobre el mapeo existente de `core/errors.py`; paginación estándar `?page&size → {items, total, page, pages}` en todos los listados
  - `Idempotency-Key` del cliente generalizado a toda mutación no-idempotente (crear venta, cobrar, emitir, cerrar caja) sobre el `operation_idempotency` existente
  - `BaseRepository[T]` con `soft_delete()` (RN-B1/B2) y paginación incluidas
  - **Decisión a registrar (no a "corregir")**: el equivalente del UoW de Food Store en Aliadata son los **RPCs SQL `SECURITY DEFINER`** — la transacción vive en Postgres, no en Python; los services no comitean (RN-C1 ya se cumple por diseño). Documentarlo en `knowledge-base/09` como DEC nueva
- **Dependencias**: ninguna (sinergia con `v3-soft-delete-policy`)
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §6, `backend/core/errors.py`, `knowledge-base/08_arquitectura_propuesta.md`

### `v3-catalog-masters` — Maestros menores: UoM tipada + direcciones (V3 §7.1, §7.3)
- **Estado**: `[x]` ✅ COMPLETADA 2026-07-06 (22/22 tasks, TDD estricto, suite 960 verde — 912 baseline + 48 nuevos)
- **Governance**: BAJO
- **Scope**:
  - `units_of_measure`: **spec-only, cero DDL** — se verificó en prod que `type` (`unit|weight|volume|length|custom`) ya es `NOT NULL` con `CHECK` y catálogo mixto (`is_system` global + `account_id` per-tenant) ya vigente. Formalizado en `openspec/specs/units-of-measure/spec.md` (sync a main en el archive), no se migró nada.
  - `client_addresses`: tabla nueva (additiva, migración `20260813000001_v3_client_addresses.sql`), direcciones operativas múltiples con `alias` e `is_primary` (invariante: exactamente una primaria viva, índice único parcial `idx_client_addresses_primary` + RPC `rpc_set_primary_client_address`); la dirección **fiscal** sigue en FiscalIdentity (inmutable por snapshot), estas son operativas/editables. UI diferida (solo DB + API + tipo TS `ClientAddress`).
- **Decisiones (D1–D6, ver design.md del change archivado)**: D1 UoM spec-only sin rename de enum; D2 `client_addresses` con `account_id` DIRECTO (scope de tenancy simple, entra a `SOFT_DELETE_TABLES`); D3 invariante "exactamente una primaria" vía índice único parcial + RPC de switch atómico; D4 soft-delete del cliente padre NO propaga (inalcanzable por lectura, reversible al reactivar); D5 API anidada 3 capas bajo `/clients/{client_id}/addresses`; D6 migración idempotente/both-worlds-safe con gate auto-limpiante.
- **Dependencias**: ninguna
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §7.1 y §7.3, `knowledge-base/04_modelo_de_datos.md` §units_of_measure y §client_addresses, `openspec/changes/archive/2026-07-06-v3-catalog-masters/`
- **Open Questions para el PO (no bloquean este change, quedan pendientes)**:
  - **OQ1**: ¿Alinear el enum de `units_of_measure.type` a la nomenclatura canónica del V3 (`peso|volumen|contable`)? Es BREAKING (CHECK + `frontend/lib/types.ts` + colapsar `length`/`custom`). Hoy 0 filas per-tenant → costo de datos mínimo, costo real es frontend/semántico. Si se aprueba, change chico aparte con migración de datos.
  - **OQ2**: ¿Reactivar un cliente debe dejar sus direcciones operativas intactas (comportamiento actual, sin cascade de soft-delete) o deben borrarse junto con el cliente?
  - **OQ3**: ¿Alcanza con dirección operativa "plana" (`street`/`city`/`province`/`postal_code`/`notes`) o hace falta georreferencia / campos AR específicos (localidad vs. departamento)?

### `v3-product-composition` — BOM ligera de un nivel (V3 §7.2, fase V3)
- **Estado**: `[ ]` pendiente — **fase V3** (no proponer antes de cerrar V2.5)
- **Governance**: MEDIO (toca el hot path de venta cuando el producto es COMPOSITE)
- **Scope**:
  - `Product.kind ('SIMPLE','COMPOSITE')` + tabla `product_components (product_id, component_id, qty, optional)`
  - Regla de stock: vender un `COMPOSITE` registra movimientos **sobre los componentes** (explosión simple de 1 nivel, dentro de la misma transacción de la venta); sin recursión multi-nivel ni órdenes de producción (eso es manufactura — fuera de alcance)
  - Casos target: combos, canastas, panadería/rotisería (segmento real)
- **Dependencias**: `v3-snapshot-pattern` (el componente congela su costo al explotar)
- **Leer antes**: `modelo-dominio-aliadata-v3.md` §7.2 y §10
