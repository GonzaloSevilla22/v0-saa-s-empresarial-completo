# Proposal — billing-schema-migration

> Change `C-01` del roadmap (`CHANGES.md`). Fase 1 — Billing y Monetización.
> Governance: **CRÍTICO** (toca datos de plan de usuario y el schema de billing).
> Dependencias: ninguna. Desbloquea: C-02 (plan-gating-engine), C-05 (multi-tenant) y el resto del camino crítico.

## Why

El schema actual de `profiles.plan` solo soporta dos valores (`'free'`, `'pro'`) y durante la beta todos los usuarios están forzados a `'pro'` (migration `20260424000001`). La propuesta comercial definitiva (`tabla_resumen_planes_aliadata.docx`, RN-03) define **4 planes reales** con límites diferenciados:

| Plan | Precio/mes | Productos | Clientes | Operaciones/mes | Consultas IA/mes | Consejos IA/mes |
|---|---|---|---|---|---|---|
| `gratis` | $0 | 100 | 50 | 100 | 5 | 3 |
| `inicial` | $24.900+IVA | 500 | 250 | 500 | 30 | 15 |
| `avanzado` ⭐ | $34.900+IVA | 1.500 | 1.000 | 2.000 | 120 | 60 |
| `pro` | $69.900+IVA | 5.000 | 3.000 | 6.000 | 300 | 150 |

Sin esta migración no se puede construir el motor de gating por plan (C-02), el período de gracia de 60 días (C-03), los contadores de IA separados (C-04) ni la arquitectura multi-tenant (C-05). Este change es el **cuello de botella estructural** de toda la fase de monetización.

Además, el tracking de IA actual (`insights_used`) mezcla dos conceptos que la tabla comercial separa: **Consultas IA** (insights/predicciones/simulador/copiloto) y **Consejos IA** (fair-advisor, sugerencias proactivas). Cada uno tiene su propio límite mensual por plan, por lo que requieren contadores independientes.

## What Changes

**Schema (`profiles`):**
- Migrar el dominio de valores de plan de 2 a 4 tiers comerciales. Para evitar romper el enum existente y los emails de la beta, el plan comercial se modela en una **nueva columna `billing_plan TEXT`** (con CHECK de 4 valores) en lugar de redefinir la columna `plan` actual — ver `design.md` para la justificación.
- Agregar columnas de billing a `profiles`:
  - `billing_plan TEXT NOT NULL DEFAULT 'gratis'` — tier comercial (`gratis|inicial|avanzado|pro`)
  - `billing_status TEXT NOT NULL DEFAULT 'trialing'` — estado de suscripción (`active|trialing|expired|cancelled`)
  - `trial_started_at TIMESTAMPTZ DEFAULT NOW()` — inicio del trial de 60 días
  - `trial_expires_at TIMESTAMPTZ` — calculado: `trial_started_at + INTERVAL '60 days'`
  - `billing_provider_customer_id TEXT` — ID de cliente Stripe/MercadoPago (nullable, billing futuro)
  - `usage_reset_at TIMESTAMPTZ NOT NULL DEFAULT NOW()` — marca del último reset mensual de uso
- Dividir el contador de IA:
  - `ai_queries_used INTEGER NOT NULL DEFAULT 0` — reemplaza semánticamente a `insights_used` (Consultas IA)
  - `ai_advice_used INTEGER NOT NULL DEFAULT 0` — nuevo contador (Consejos IA / fair-advisor)
  - `insights_used` se mantiene por compatibilidad y se backfillea a `ai_queries_used`.

**Tabla `plan_limits` (nueva, seed con los 4 planes):**
- Fuente de verdad de los límites por plan (productos, clientes, proveedores, operaciones/mes, historial, exportaciones, consultas IA, consejos IA, usuarios, sucursales, flags de features). Evita hardcodear límites en código.
- RLS: lectura pública (sin auth), escritura solo admin.

**Tabla `billing_events` (nueva):**
- Audit trail inmutable de cambios de plan/estado (`event_type`, `from_plan`, `to_plan`, `reason`, `metadata`, `created_at`). Dominio CRÍTICO → trazabilidad obligatoria.

**Código:**
- `lib/constants.ts`: reemplazar el objeto de límites hardcodeado (`maxProducts: 20` / `Infinity`) por las constantes de los 4 planes derivadas de RN-03 (el fetch dinámico desde `plan_limits` se implementa en C-02; aquí se dejan las constantes alineadas).
- `lib/types.ts`: tipo `Plan = 'gratis' | 'inicial' | 'avanzado' | 'pro'`, tipo `BillingStatus`, e interfaz `PlanLimits`.

**Migración de datos existentes:**
- Todos los usuarios actuales (`plan = 'pro'` por beta) se mapean a `billing_plan = 'pro'`, `billing_status = 'trialing'`, con `trial_started_at = COALESCE(created_at, NOW())` para preservar la ventana de gracia real de cada usuario.

## Impact

- **Affected specs:** `billing` (nueva capability — define el modelo de planes, límites y estado de suscripción).
- **Affected code:**
  - `supabase/migrations/` — nueva migración de schema + seed de `plan_limits` + backfill.
  - `lib/constants.ts` — límites de los 4 planes.
  - `lib/types.ts` — tipos `Plan`, `BillingStatus`, `PlanLimits`.
  - Tipos generados de Supabase (`lib/database.types.ts` o equivalente) — regenerar tras la migración.
- **No rompe:** ninguna lógica de gating se activa en este change (eso es C-02). Esta migración es **aditiva**: agrega columnas/tablas y backfillea. La columna `plan` legacy permanece intacta.
- **Riesgo CRÍTICO (requiere aprobación humana antes de aplicar):** es una migración sobre datos reales de usuarios. Ver `design.md` §"Decisiones que requieren aprobación".
