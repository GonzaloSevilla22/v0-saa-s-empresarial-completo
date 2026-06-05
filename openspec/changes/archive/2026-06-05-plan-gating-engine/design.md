## Context

C-01 creó el schema de billing: `profiles.billing_plan`, `profiles.billing_status`, `profiles.trial_plan`, `profiles.trial_expires_at`, `profiles.ai_queries_used`, `profiles.ai_advice_used`, y la tabla `plan_limits` sembrada con los 4 planes. El código actual todavía gatéa con `user.plan === "pro"` (columna ENUM legacy) y usa constantes hardcodeadas.

C-02 conecta ese schema con la app: lee límites en runtime, determina el "plan efectivo" del usuario (considerando trials), y aplica restricciones reales.

## Goals / Non-Goals

**Goals**
- Hook `usePlanLimits()`: fetch de `plan_limits` desde DB, cacheado por React Query.
- Hook `usePlanGate()`: determinar si el usuario tiene acceso a una feature o recurso numérico.
- Migrar todos los checks `user.plan === "pro"` → `user.billingPlan` con jerarquía real.
- Aplicar límites numéricos (productos, clientes) con CTA de upgrade al alcanzar el tope.
- Gating de features exclusivas (rentabilidad, reportes, sugerencia de precios).
- Límites de IA: verificación server-side en Edge Functions antes de llamar a OpenAI.
- RLS actualizada: `posts`/`replies` INSERT verifica `billing_plan` en lugar de `plan` legacy.
- Plan Trial: si `billing_status = 'trialing'` y `trial_expires_at > now()`, usar `trial_plan` como plan efectivo.

**Non-Goals**
- Lógica de vencimiento de trial y downgrade automático → C-03 (`grace-period-logic`).
- UI de upgrade/pago → C-10 (`subscription-ui-upgrade-flow`).
- Multi-usuario dentro de un plan → C-05 (`multi-user-tenant-architecture`).
- Split de contadores IA en Edge Functions (wiring completo) → C-04 (`ai-usage-counters-split`).

## Decisions

### D1 — Plan efectivo = `billing_plan` con override por trial activo
**Decisión**: el "plan efectivo" del usuario se calcula así:
```typescript
function getEffectivePlan(user: User): Plan {
  const now = new Date()
  const trialActive =
    user.billingStatus === 'trialing' &&
    user.trialPlan != null &&
    user.trialExpiresAt != null &&
    new Date(user.trialExpiresAt) > now
  return trialActive ? (user.trialPlan as Plan) : user.billingPlan
}
```
**Por qué**: usuarios nuevos tienen `billing_plan = 'gratis'` + `trial_plan = 'avanzado'` por 30 días. Durante el trial acceden a los límites de Avanzado. Expuesto desde `useAuth()` como `user.effectivePlan` (campo calculado, no persistido en DB).

### D2 — Jerarquía de planes como array ordenado
**Decisión**: `PLAN_HIERARCHY = ['gratis', 'inicial', 'avanzado', 'pro']`. Una feature disponible a partir de `'avanzado'` se verifica como `PLAN_HIERARCHY.indexOf(effectivePlan) >= PLAN_HIERARCHY.indexOf('avanzado')`.
**Por qué**: evita hardcodear comparaciones binarias y es extensible si se agregan planes.

### D3 — `usePlanLimits()`: React Query + anon key (lectura pública de `plan_limits`)
**Decisión**: `plan_limits` tiene RLS de lectura pública (C-01). El hook usa el Supabase client normal y cachea por 1 hora (`staleTime: 3_600_000`). No requiere auth. Retorna los límites del plan efectivo del usuario.
**Por qué**: los límites cambian raramente (solo cuando el admin actualiza `plan_limits`). Un staleTime largo reduce llamadas. Si el usuario cambia de plan, se invalida el cache mediante `queryClient.invalidateQueries(['planLimits'])`.

### D4 — Gating numérico: client-side check + bloqueo UX (no server-side en esta fase)
**Decisión**: los límites de productos, clientes, proveedores y operaciones se verifican en el cliente antes de mostrar el formulario de creación. Si el count actual >= límite del plan: se muestra un banner de "Límite alcanzado — Actualizá tu plan" en lugar del botón "Nuevo". No hay validación server-side de estos límites en C-02.
**Por qué**: la validación server-side real (RPC que rechace si se supera el límite) es C-02 scope medio — se puede agregar en C-02 o en una iteración futura. El check client-side es suficiente para el MVP y evita complejidad en los RPCs existentes.
**Trade-off**: un usuario técnico puede saltear el check UI. Aceptado para el MVP; el riesgo es bajo porque los límites son por recursos creados, no por transacciones de dinero.

### D5 — Límites de IA: verificación server-side en Edge Functions
**Decisión**: las Edge Functions de IA (ai-insights, ai-prediccion, ai-resumen, ai-simulador, ai-copiloto, fair-advisor) verifican `ai_queries_used` vs `plan_limits.max_ai_queries_per_month` antes de llamar a OpenAI. Si el usuario excedió su cuota, retornan `{ ok: false, error: 'quota_exceeded', resetAt: usage_reset_at }` con HTTP 429.
**Por qué**: las llamadas a IA tienen costo real (OpenAI). El check server-side es no-negociable para límites con implicancia económica.
**Implementación**: la Edge Function hace `SELECT ai_queries_used, usage_reset_at FROM profiles WHERE id = auth.uid()` + `SELECT max_ai_queries_per_month FROM plan_limits WHERE plan = $effectivePlan`.

### D6 — RLS de comunidad: migrar de `plan = 'pro'` a `billing_plan IN ('avanzado', 'pro')`
**Decisión**: nueva migration que dropea las policies `posts_pro_insert` y `replies_pro_insert` (creadas en C-09) y las recrea verificando `billing_plan IN ('avanzado', 'pro')`.
**Por qué**: el plan legacy `plan = 'pro'` fue un hack temporal. Ahora `billing_plan` es la fuente de verdad. Los usuarios con `billing_plan = 'avanzado'` deben poder postear (la tabla de planes los incluye en comunidad completa).

### D7 — `PlanGate` component: refactor con jerarquía
**Decisión**: `PlanGate` recibe `requiredPlan: Plan` y compara `getEffectivePlan(user)` contra `requiredPlan` usando `PLAN_HIERARCHY`. Muestra un bloque de "upgrade" si el plan efectivo es insuficiente.
**Por qué**: la lógica actual `user.plan === "pro"` no soporta planes intermedios (inicial, avanzado). Con 4 planes, se necesita comparación posicional.

## Estándares aplicados (skill-registry)

**vercel-react-best-practices**:
- `usePlanLimits` usa React Query: `useQuery(['planLimits', effectivePlan], ...)` — nunca en Client Component directamente.
- No `useEffect` para derivar `effectivePlan` — se deriva durante render.

**nextjs-app-router-patterns**:
- `usePlanLimits` es un hook de Client Component. Server Components que necesitan límites para renderizado inicial los leen directamente de Supabase.

**supabase-postgres-best-practices**:
- RLS policy usa `(select auth.uid())` envuelto.
- `UPDATE profiles SET ai_queries_used = ai_queries_used + 1` en Edge Functions (atómico).

## Migration Plan

1. Nueva migration `<timestamp>_gating_rls_update.sql`:
   - Drop + recreate policies de INSERT en `posts` y `replies` usando `billing_plan`.
2. Nuevos hooks: `lib/hooks/usePlanLimits.ts`, `lib/hooks/usePlanGate.ts`.
3. Actualizar `contexts/auth-context.tsx`: agregar `effectivePlan` calculado en el User object.
4. Refactorizar `components/shared/plan-gate.tsx`.
5. Actualizar refs en UI: comunidad, configuracion, cursos, sidebar, insights, productos.
6. Actualizar Edge Functions IA (ai-insights primero como referencia, resto en paralelo).
7. `tsc --noEmit` + `npx supabase db push` para la migration de RLS.

## Open Questions

- ¿Qué CTA mostrar cuando el usuario alcanza el límite numérico? (texto, link a /planes — definir en C-10)
- ¿El límite de operaciones mensuales se resetea con `usage_reset_at`? (mismo campo que IA) — **Suposición**: sí, mismo reset mensual. C-04 lo formaliza.
