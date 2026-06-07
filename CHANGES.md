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
```

> Nota: workers de IA/OCR (Edge Functions: `ai-insights`, `ai-prediccion`, `ai-resumen`, `ai-simulador`, `fair-advisor`, `invoice-ocr`) **NO se migran en esta fase** — permanecen como Supabase Edge Functions (ver DEC-15). Pospuesto hasta contar con presupuesto para Render paid y volumen que justifique workers Python (ARQ/LangChain).
>
> **Scaffolding archivado**: el change `fastapi-backend-monorepo` (2026-06-06) ya implementó: monorepo `frontend/` + `backend/`, FastAPI `backend/main.py`, auth JWT Supabase (`core/auth.py`, HS256), WebSocket manager (`core/ws_manager.py`, `/ws/{room_id}`), `pnpm-workspace.yaml` y 8 tests. Archivado en `openspec/changes/archive/2026-06-06-fastapi-backend-monorepo/`. La FASE 5 cubre lo **pendiente**.

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
```

### Camino crítico (6 changes originales + 4 nuevos — mínimo irreducible)

```
C-01 → C-02 → C-03 → C-10 → C-05 → C-07*

[scaffold archivado] → C-15 → C-16 → C-17**
                              └── C-18
```

> `*` C-07 (sucursales) es la feature de mayor valor diferencial del plan PRO.
> C-08 (stock multisucursal) está en desarrollo activo para septiembre 2026 y se agrega tras C-07.
> `**` C-17 es CRÍTICO (dinero real); requiere aprobación humana explícita antes de cortar el webhook de pagos.
> La cadena C-15 → C-16 → {C-17, C-18} es independiente del camino crítico original y puede correrse en cualquier momento post-MVP.

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
- **Estado**: `[ ]` pendiente
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
| C-17 | backend-payments-migration | 5 — Migración Python | CRITICO | C-16 | `[ ]` |
| C-18 | frontend-decouple-datacontext | 5 — Migración Python | MEDIO | C-16 | `[x]` |

---

## Primer change recomendado

`C-01` (`billing-schema-migration`) es el primer change a implementar — es CRITICO, sin dependencias, y desbloquea el camino crítico completo. Puede correrse en paralelo con `C-09` (community-bug-fixes).

**Para la Fase 5**: `C-15` (`backend-data-layer`) puede iniciarse en cualquier momento — el scaffolding ya está archivado en `openspec/changes/archive/2026-06-06-fastapi-backend-monorepo/`, este change solo agrega la capa de datos (asyncpg + repositories + get_auth_context + errores).

Para arrancar la Fase 5: `/opsx:propose backend-data-layer`
