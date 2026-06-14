## Why

Los insights viven hoy en **dos tablas con esquemas y writers distintos**, y eso provoca pérdida silenciosa de datos para el usuario:

- `ai_insights` (canónica): columnas `message`/`type`/`priority`/`account_id`. La escriben directo 4 Edge Functions (`ai-insights`, `ai-precio`, `ai-rentabilidad`, `ai-comparativo`).
- `insights` (legacy): columnas `content`/`actionable`, **sin `account_id`**. La escribe el RPC `rpc_atomic_log_ai_insight`, invocado por otras 3 Edge Functions (`ai-prediccion`, `ai-resumen`, `ai-simulador`).

El **frontend lee únicamente `ai_insights`**, por lo que todo insight generado por predicción/resumen/simulador se guarda en la tabla legacy y **nunca se le muestra al usuario**. La duplicación también contradice el modelo de dominio V2 (`Insight` unificado, DEC-21) y deja `insights` como tabla en retirada que sigue recibiendo escrituras.

## What Changes

- **Migrar** todas las filas de la tabla legacy `insights` al esquema canónico, derivando los campos faltantes: `content → message`, `account_id` derivado por join `user_id → account_members`, `priority` derivado de `actionable`.
- **Renombrar** `ai_insights → insights` como nombre definitivo del dominio unificado (Decisión PO 2026-06-10, **Opción A** — sin tabla transitoria).
- **BREAKING (interno)** Reescribir el RPC `rpc_atomic_log_ai_insight` para que inserte en el esquema canónico (`message`/`priority`/`account_id`) en vez de `content`/`actionable`, preservando el contador de plan (`profiles.insights_used`) y la telemetría.
- **BREAKING (interno)** Eliminar la tabla legacy `insights` una vez migrada y sin writers/readers apuntando a ella.
- **Repuntar** todas las referencias de código de `ai_insights` al nombre canónico `insights`: 7 Edge Functions, el RPC, el frontend (hook `use-insights`, `aiInsightService`, páginas dashboard/insights/comparativo/rentabilidad) y regenerar `database.types.ts`.
- **Vista de compatibilidad** transitoria durante el deploy para evitar ventana de rotura entre el rename de DB y el despliegue del código.

> No-goes (RN-97): no se agrega ninguna funcionalidad nueva sobre `insights` legacy; el change solo retira deuda y unifica.

## Capabilities

### New Capabilities
- `insights`: modelo unificado de Insight — una única tabla canónica account-scoped (`message`, `type`, `priority`, `account_id`, `user_id`, `created_at`), con un único camino de escritura (Edge Functions directas + RPC `rpc_atomic_log_ai_insight`) y de lectura (frontend vía `use-insights`). Cubre la migración de datos legacy, el rename y la retirada de la tabla `insights` vieja.

### Modified Capabilities
<!-- Ninguna: no existe spec previa de insights en openspec/specs/. -->

## Impact

- **DB / migraciones** (`supabase/migrations/`): nueva migración de backfill legacy→canónico, rewrite de `rpc_atomic_log_ai_insight`, rename `ai_insights → insights`, drop de `insights` legacy, vista de compatibilidad transitoria. Las RLS policies e índices de `ai_insights` viajan con el rename.
- **Edge Functions** (`supabase/functions/`): `ai-insights`, `ai-precio`, `ai-rentabilidad`, `ai-comparativo` (insert directo → repuntar a `insights`); `ai-prediccion`, `ai-resumen`, `ai-simulador` (vía RPC — sin cambio de llamada, el RPC se reescribe).
- **Frontend** (`frontend/`): `hooks/data/use-insights.ts`, `lib/services/aiInsightService.ts`, `app/(dashboard)/{dashboard,insights,reportes/comparativo,rentabilidad}/page.tsx`, `lib/database.types.ts` (regenerar).
- **Datos en producción**: migración de las filas legacy (proyecto real `gxdhpxvdjjkmxhdkkwyb`). Riesgo de pérdida si el mapeo de `account_id` falla para usuarios sin membership → requiere estrategia de fallback.
- **Gating de plan**: el contador `profiles.insights_used` debe seguir incrementándose igual tras el rewrite del RPC.
