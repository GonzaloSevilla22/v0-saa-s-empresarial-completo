# Tasks — billing-edge-effective-plan

> **Governance: CRÍTICO (billing).** No ejecutar ninguna task sin sign-off explícito del PO
> sobre OQ-1 … OQ-4 (`proposal.md` § Open Questions). La task 0.1 es el gate.
>
> **Strict TDD.** Cada task de código sigue RED → GREEN → TRIANGULATE → REFACTOR.
> Runner: `pnpm vitest run` desde `frontend/` (D6 — no se agrega toolchain de Deno).
> Gates SQL embebidos en la migración, patrón `billing-pro-trial` / `v31-fsm-status-triggers`.

## 0. Gate de sign-off (bloqueante)

- [x] 0.1 **Sign-off explícito del PO obtenido 2026-07-31.** Las 4 Open Questions quedan resueltas exactamente según la recomendación de `proposal.md`:
  - **OQ-1 (vía de invocación): opción (B)** — wrapper `rpc_my_effective_plan()` sin argumentos, `GRANT EXECUTE` a `authenticated`. Se ejecuta la sección 2 tal cual está escrita (ver 0.2).
  - **OQ-2 (contadores de uso): fuera de alcance.** No se tocan `ai_queries_used`/`ai_advice_used`/`exports_used`/`usage_reset_at` en este change. Queda anotado como deuda para un change propio `billing-usage-counters-per-account` (task 8.5).
  - **OQ-3 (comportamiento ante error transitorio): fail-closed en la resolución del plan** (degrada a `'gratis'`, nunca a un plan superior), **fail-open conservado en la lectura de `plan_limits`** (sin fila de límites no hay contra qué comparar).
  - **OQ-4 (usuario multi-cuenta): regla determinista y documentada** — cuenta de la membresía más antigua (`account_members.created_at` ASC), desempate por `account_id`. No se introduce "cuenta activa" seleccionable (eso es `v3-rbac-multirole`).
- [x] 0.2 **N/A.** OQ-1 se resolvió como opción (B), no (A) `service_role`. La sección 2 se ejecuta sin modificaciones respecto de lo escrito.

## 1. Red de seguridad (baseline antes de tocar nada)

- [x] 1.1 `pnpm vitest run` en `frontend/` (tras `pnpm install`, worktree sin `node_modules`). **Baseline: 610 tests / 83 archivos, 609 passed + 1 timeout flake** (`idle-server-enforcement.test.ts` > `'/auth/login' is NOT in PROTECTED_PREFIXES...`, `Test timed out in 5000ms`). Re-ejecutado el archivo aislado: **24/24 passed** — confirmado flake de carga/entorno (contención de recursos durante `import` de 177s en la corrida completa), no relacionado con ningún archivo de este change. Reportado como fallo preexistente/flake, NO se toca.
- [x] 1.2 `pytest` desde la raíz del repo apuntando a `backend/tests` con `-c backend/pyproject.toml` (ejecutarlo con cwd=`backend/` rompe los tests que resuelven `supabase/migrations/...` por ruta relativa — no es un fallo real, es cwd). **Baseline: 1041 passed, 3 skipped**, 0 failures. Este change no toca `backend/`.
- [x] 1.3 Verificado con MCP read-only sobre `gxdhpxvdjjkmxhdkkwyb`: join de `profiles` × `account_members` comparando el rank de `profiles.billing_plan` contra el rank de `get_effective_plan(account_id)` para las 34 cuentas reales. **0 filas** donde el rank de `profiles.billing_plan` supera al del plan efectivo de la cuenta — confirma el análisis de `design.md` § Risks: ninguna cuenta pierde acceso al desplegar este change.

## 2. RPC `rpc_my_effective_plan()` (migración aditiva)

- [ ] 2.1 RED — Escribir los gates SQL de la migración antes que su cuerpo: (a) existe exactamente 1 definición de `rpc_my_effective_plan`, `STABLE` + `SECURITY DEFINER`; (b) `authenticated` tiene `EXECUTE` sobre `rpc_my_effective_plan`; (c) `authenticated` y `anon` **siguen sin** `EXECUTE` sobre `get_effective_plan(uuid)` (no se debilitó D2 de `billing-pro-trial`); (d) `get_effective_plan` conserva 1 sola definición (lección 42725).
- [ ] 2.2 GREEN — Crear `supabase/migrations/<timestamp>_billing_edge_effective_plan.sql` con `rpc_my_effective_plan()`: sin argumentos, `STABLE SECURITY DEFINER`, `SET search_path = public, pg_temp`, resuelve la cuenta del llamador reutilizando `public.current_account_ids()` (D2), delega en `public.get_effective_plan(...)`, devuelve `'gratis'` si no hay cuenta resoluble (fail-closed, D5). `REVOKE` de `PUBLIC`/`anon` + `GRANT EXECUTE` a `authenticated`. `COMMENT ON FUNCTION` documentando la regla de desempate multi-cuenta.
- [ ] 2.3 TRIANGULATE — Agregar gates SQL de comportamiento, ejecutables solo con `public.accounts` vacía (CI), con anchor sintético vía `auth.users` y limpieza best-effort: cuenta nueva en trial resuelve `'pro'`; cuenta con `billing_exempt = true` y trial vencido resuelve `'pro'`; cuenta con `billing_plan = 'inicial'` sin trial resuelve `'inicial'` para los 5 valores posibles de `billing_status` (confirma que `billing_status` no influye); usuario sin membresía resuelve `'gratis'`.
- [ ] 2.4 TRIANGULATE — Gate de comportamiento para el caso multi-cuenta: un usuario miembro de dos cuentas obtiene un resultado determinista y repetible (dos invocaciones consecutivas devuelven lo mismo), sin error.
- [ ] 2.5 REFACTOR — Verificar que la migración es reaplicable sin efecto acumulativo (el pipeline la aplica dos veces por diseño): `DROP FUNCTION IF EXISTS` de la firma previa antes de crear, sin backfill de datos. Documentar cabecera con CHANGE / design ref / rollback / verificación post-merge, siguiendo el formato de `20260817000001`.

## 3. Módulo compartido de resolución del plan efectivo

- [ ] 3.1 RED — Crear `frontend/__tests__/edge-effective-plan.test.ts` que **importe el archivo real** `supabase/functions/_shared/effective-plan.ts` por ruta relativa (todavía inexistente → falla) e inyecte un doble del cliente Supabase. Primer caso: el RPC devuelve `'pro'` → la resolución devuelve `'pro'`.
- [ ] 3.2 GREEN — Crear `supabase/functions/_shared/effective-plan.ts` exportando la resolución **pura e inyectable** (recibe el cliente como parámetro). Restricción de diseño obligatoria (D6): **ninguna referencia a `Deno.*` en scope de módulo**, o el archivo deja de ser importable por vitest. Tipar sin `any` (regla dura del proyecto); si hace falta un tipo estructural para el cliente, definir la interfaz mínima necesaria en el propio módulo.
- [ ] 3.3 TRIANGULATE — Agregar casos: el RPC devuelve `'gratis'`; el RPC devuelve `null`/vacío → `'gratis'`; el RPC devuelve error → `'gratis'` **y** se registra el error (fail-closed observable, D5); el RPC devuelve un valor no reconocido → `'gratis'`.
- [ ] 3.4 TRIANGULATE — Caso de aislamiento: la resolución no acepta ni propaga un `account_id` provisto por el llamador (cubre el escenario de spec "Una Edge Function no puede consultar el plan de otra cuenta").
- [ ] 3.5 REFACTOR — Dejar una única exportación pública del módulo y confirmar que los tests siguen verdes.

## 4. `_shared/ai-quota.ts` — cuota de IA (8 Edge Functions)

- [ ] 4.1 RED — Extender `frontend/__tests__/` con el caso que hoy falla: cuenta con `accounts.billing_plan = 'pro'` y `profiles.billing_plan = 'gratis'`, contador en 10 → la cuota debe permitir la llamada (límite 300, no 5).
- [ ] 4.2 GREEN — Reescribir `checkAiQuota` para obtener el plan efectivo desde el módulo de la sección 3, y **eliminar** la función local `getEffectivePlan` (`ai-quota.ts:31-45`) junto con las columnas de billing del `select` a `profiles` (`ai-quota.ts:59`). El `select` a `profiles` queda reducido a los contadores (`ai_queries_used`, `ai_advice_used`, `usage_reset_at`) — D3: los contadores NO se migran en este change.
- [ ] 4.3 TRIANGULATE — Casos: cuenta exenta con `billing_plan = 'gratis'` → límite de `'pro'`; trial vencido → límite del plan base; contador por encima del límite → `allowed: false` con el cuerpo 429 intacto (`{ ok:false, error:'quota_exceeded', resetAt, used, limit }`, D7); `plan_limits` ilegible → fail-open conservado (D5).
- [ ] 4.4 TRIANGULATE — Verificar que `incrementAiUsage` sigue llamando a `rpc_increment_ai_usage` sin cambios (el contador sigue siendo por usuario, D3) y que ninguna de las 8 funciones consumidoras requiere cambios en su call site.
- [ ] 4.5 REFACTOR — Confirmar que no queda ninguna referencia a `billing_plan`, `billing_status`, `trial_plan` ni `trial_expires_at` en `_shared/ai-quota.ts`.

## 5. `ai-precio` — gate de plan por flag canónico

- [ ] 5.1 RED — Test que falla hoy: cuenta con plan efectivo `'pro'` cuyo `profiles.billing_plan` es `'gratis'` → `ai-precio` no debe responder 403.
- [ ] 5.2 GREEN — Reemplazar en `ai-precio/index.ts` la lectura de `profiles` y la lógica de trial inline (líneas ~129-146) por el módulo de la sección 3, y el array hardcodeado `allowedPlans = ['avanzado','pro']` (línea ~148) por la lectura de `plan_limits.has_price_suggestion` del plan efectivo (D4). Conservar exactamente el cuerpo 403 `{ ok:false, error:'plan_required', required_plan:'avanzado' }` (D7).
- [ ] 5.3 TRIANGULATE — Casos: plan con `has_price_suggestion = false` → 403; plan con el flag en `true` → procede; cuenta exenta → procede; cambio del flag en la tabla altera la decisión sin tocar código (cubre el escenario de spec correspondiente).
- [ ] 5.4 TRIANGULATE — Reemplazar el `.single()` sobre `account_members` (líneas ~111-115) por la resolución determinista de la sección 3 y cubrir el caso de usuario con 2+ membresías, que hoy produciría un error (OQ-4).
- [ ] 5.5 REFACTOR — Verificar que la resolución de `accountId` usada para las consultas de tenancy (`products`, `sales`) sigue siendo la misma cuenta que la usada para el gate, sin dos resoluciones divergentes en el mismo archivo.

## 6. `generate-export` — cuota e historial por plan efectivo

- [ ] 6.1 RED — Test que falla hoy: cuenta con plan efectivo `'pro'` y `profiles.billing_plan = 'gratis'` → la exportación no debe responder 403 `export_not_allowed`.
- [ ] 6.2 GREEN — Reemplazar en `generate-export/index.ts` la función local `getEffectivePlan` (líneas ~24-37) y la lectura de billing desde `profiles` (líneas ~180-190) por el módulo de la sección 3. El `select` a `profiles` queda reducido a `exports_used` (D3).
- [ ] 6.3 TRIANGULATE — Casos: plan efectivo `'gratis'` → 403 `export_not_allowed`; cuota agotada → 429 con `resetAt`; cuenta exenta → permitida; `history_days` corresponde al plan efectivo y no al de `'gratis'` (cubre el escenario de spec de ventana de historial).
- [ ] 6.4 REFACTOR — Confirmar que el cliente `service_role` de esta función sigue usándose **solo** para Storage (upload + signed URL) y no se extendió a la resolución de plan.

## 7. Verificación integral

- [ ] 7.1 `pnpm vitest run` en verde, con el conteo del baseline de 1.1 más los tests nuevos. Ejecutar dos veces para descartar flakes.
- [ ] 7.2 Suite de backend sin cambios respecto del baseline de 1.2 (este change no toca `backend/`).
- [ ] 7.3 Barrido final: `grep` sobre `supabase/functions/` confirmando **cero** ocurrencias de `billing_plan`, `billing_status`, `trial_plan` y `trial_expires_at`, y una sola vía de resolución del plan efectivo en todo el directorio.
- [ ] 7.4 Verificar que `frontend/lib/plan-utils.ts` y su prueba de paridad no fueron modificados (fuera de alcance) y siguen verdes.
- [ ] 7.5 Revisar que ningún archivo tocado introduce `any` ni `as import("...")` (reglas duras del proyecto).

## 8. Despliegue y verificación post-merge

- [ ] 8.1 Confirmar el orden de despliegue (D6 § Migration Plan): la migración se aplica **antes** de que las Edge Functions nuevas queden activas. Desplegar las funciones solo después de verificar que el RPC existe en el proyecto real.
- [ ] 8.2 Verificación read-only post-merge sobre `gxdhpxvdjjkmxhdkkwyb`: 1 sola definición de `rpc_my_effective_plan`; `has_function_privilege('authenticated', 'public.rpc_my_effective_plan()', 'EXECUTE')` = true; `has_function_privilege('authenticated', 'public.get_effective_plan(uuid)', 'EXECUTE')` = **false** (D2 intacta).
- [ ] 8.3 Verificar contra la cuenta con pago reconciliado que su plan efectivo resuelto es el plan pagado, y que puede ejecutar una exportación y una consulta de IA.
- [ ] 8.4 Revisar los logs de las Edge Functions durante las primeras 24 h buscando el `console.error` de degradación fail-closed (D5): su ausencia confirma que la resolución no está fallando de forma silenciosa.
- [ ] 8.5 Registrar en `CHANGES.md` el cierre del change y dejar anotada la deuda de OQ-2 (contadores por usuario) como candidato a `billing-usage-counters-per-account`.
