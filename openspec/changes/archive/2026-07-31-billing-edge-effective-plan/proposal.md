## Why

Tres archivos de Edge Functions computan el plan efectivo del usuario leyendo `public.profiles` con una copia local de la lógica de trial, en vez de la definición normativa `public.get_effective_plan(account_id)` que introdujo `billing-pro-trial` (migración `20260817000001`, PR #313).

La auditoría de este propose encontró que **ninguna capa del sistema escribe `profiles.billing_plan`**. La columna se creó en `20260605000001_billing_schema.sql` con `DEFAULT 'gratis'` y desde entonces no hay un solo `UPDATE` sobre ella en migraciones, backend Python ni frontend. La autoridad de facturación vive en `public.accounts`: el webhook de pagos escribe `accounts.billing_plan` (`backend/services/payments.py:168`), la exención de cortesía es `accounts.billing_exempt`, y `get_effective_plan` lee esa tabla.

Consecuencia en producción, hoy:

- **Una cuenta que pagó** queda con `accounts.billing_plan = 'pro'` y `profiles.billing_plan = 'gratis'`. Las Edge Functions leen `profiles` → la tratan como plan **gratis**: 5 consultas de IA al mes en vez de 300, y exportaciones bloqueadas con HTTP 403 `export_not_allowed`. Es decir, **un cliente que pagó recibe el producto que no pagó**.
- **Una cuenta exenta** (`accounts.billing_exempt = true`, precedencia máxima según `get_effective_plan`) es invisible para las Edge Functions: también la tratan como gratis.
- Los usuarios en trial funcionan **por accidente**: `set_new_user_trial()` escribe `profiles.trial_plan`/`billing_status` además de `accounts`, así que la copia stale coincide durante los primeros 30 días. Cualquier ajuste posterior del trial hecho sobre `accounts` no se refleja.

Esto contradice de forma directa el requisito ya normativo de la capability `plan-gating` ("Ninguna capa SHALL redefinir la regla por su cuenta") y deja el gating de IA y exportaciones divergente del plan real de la cuenta.

## What Changes

- `supabase/functions/_shared/ai-quota.ts` deja de leer `profiles` y de reimplementar `getEffectivePlan()`; obtiene el plan efectivo desde la DB. **Radio de impacto: 8 Edge Functions** (`ai-insights`, `ai-comparativo`, `ai-precio`, `ai-prediccion`, `ai-rentabilidad`, `ai-resumen`, `ai-simulador`, `fair-advisor`) consumen este helper.
- `supabase/functions/ai-precio/index.ts` deja de reimplementar la lógica de trial para su chequeo de plan, y **deja de comparar contra el array hardcodeado `['avanzado','pro']`**: usa el flag canónico `plan_limits.has_price_suggestion`, alineándose con el requisito ya vigente "Lectura de límites desde DB en runtime".
- `supabase/functions/generate-export/index.ts` deja de leer `profiles.billing_*` y de reimplementar la lógica de trial para resolver el plan con el que compara `max_exports_per_month` / `history_days`.
- Se agrega un módulo compartido `supabase/functions/_shared/effective-plan.ts` con una única vía de resolución del plan efectivo, **puro e inyectable** (sin referencias a `Deno.*` en scope de módulo) para que sea importable por el runner de tests que ya usa el repo.
- Se agrega el RPC delgado `public.rpc_my_effective_plan()` — sin argumentos, resuelve la cuenta del llamador y delega en `get_effective_plan`. Es necesario porque `get_effective_plan(uuid)` tiene `EXECUTE` **revocado** de `authenticated`/`anon` por decisión deliberada de `billing-pro-trial` (D2), y las Edge Functions llaman con el JWT del usuario. Ver `design.md` D1.
- Se agrega cobertura de tests para la resolución del plan efectivo en Edge Functions, con el runner que el repo ya tiene (vitest), más gates SQL en la migración del RPC.

**NO cambia**: los contadores de uso (`ai_queries_used`, `ai_advice_used`, `exports_used`, `usage_reset_at`) siguen viviendo y operando en `profiles`. Ver `design.md` D3 y OQ-2 — son funcionales hoy, y migrarlos a `accounts` es un change propio.

## Capabilities

### New Capabilities

Ninguna. Este change hace que una capa existente cumpla requisitos ya normados.

### Modified Capabilities

- `plan-gating`: el comportamiento "Cuota IA aplica a todas las Edge Functions de IA (C-04)" pasa a exigir que el plan efectivo contra el que se resuelve el límite provenga de la definición normativa de la DB, y no de una copia local sobre `profiles`. Se agrega el requisito de que la capa Edge Function no redefina la regla.
- `ai-price-suggestion`: el gating de la Edge Function `ai-precio` pasa de un array de planes hardcodeado al plan efectivo de la cuenta + el flag `plan_limits.has_price_suggestion`.
- `data-export`: el gating de cuota de exportaciones pasa a resolverse contra el plan efectivo de la cuenta (`accounts`), no contra la copia en `profiles`.

## Impact

**Código afectado**
- `supabase/functions/_shared/ai-quota.ts` (afecta a 8 Edge Functions de IA)
- `supabase/functions/_shared/effective-plan.ts` (nuevo)
- `supabase/functions/ai-precio/index.ts`
- `supabase/functions/generate-export/index.ts`
- Migración nueva: `public.rpc_my_effective_plan()` + grants + gates SQL
- Tests nuevos bajo `frontend/__tests__/`

**Datos / producción**
- Sin migración de datos. El RPC nuevo es aditivo y no modifica ninguna fila.
- Efecto al desplegar: las cuentas con plan pagado o exención **recuperan** el acceso que les corresponde. Ninguna cuenta pierde acceso salvo que hoy lo tuviera por una copia stale más alta que su plan real — condición que la auditoría no encontró (`profiles.billing_plan` nunca sube de su default).

**Governance: CRÍTICO** (billing, 34 cuentas reales, una con pago reconciliado).
Este propose es **solo análisis y artefactos OpenSpec**. No se escribió ni se modificó código de producción. **`/opsx:apply` queda bloqueado hasta sign-off explícito del PO**, incluida la resolución de las Open Questions de abajo.

## Open Questions (requieren decisión del PO antes del apply)

**OQ-1 — Cómo invocan las Edge Functions la regla normativa.**
`get_effective_plan(uuid)` está revocada para `authenticated` (decisión D2 de `billing-pro-trial`: es `SECURITY DEFINER` y toma un `account_id` arbitrario, así que concederla permitiría a cualquier usuario sondear el plan de cuentas ajenas). Opciones: (A) usar un cliente `service_role` dentro de la Edge Function, sin migración; (B) crear el wrapper `rpc_my_effective_plan()` sin argumentos, `GRANT` a `authenticated`; (C) conceder `get_effective_plan` a `authenticated`.
**Recomendación: (B)**. No propaga `service_role` a 8 funciones de IA que hoy no lo usan, es imposible que devuelva el plan de una cuenta ajena, respeta D2 al pie de la letra y queda reutilizable. (C) queda descartada por seguridad. Detalle en `design.md` D1.

**OQ-2 — Contadores de uso: ¿entran en este change?**
Hallazgo: los contadores **no están rotos**. Viven solo en `profiles` (no existe columna equivalente en `accounts`), la fila de `profiles` existe para cada usuario (la crea `handle_new_user`), `rpc_increment_ai_usage` funciona y el cron mensual de reset funciona. Lo que sí ocurre es que son **por usuario, no por cuenta**: una cuenta de 3 miembros dispone de 3× la cuota de su plan.
**Recomendación: dejarlos fuera.** Corregir el plan sin tocar los contadores es una mejora estricta y sin regresión (un usuario PRO pasa de 5 a 300 consultas). Migrarlos a `accounts` implica migración de esquema + backfill + 8 Edge Functions + el cron + los hooks del frontend: es un change propio (`billing-usage-counters-per-account`).

**OQ-3 — Comportamiento ante error transitorio al resolver el plan.**
Hoy `checkAiQuota` falla **abierto** (si no puede leer el perfil, deja pasar). `get_effective_plan` es fail-**closed** (`'gratis'`). Alinearse con la DB significa que un error transitorio degrada temporalmente a un cliente que paga.
**Recomendación: fail-closed en la resolución del plan** (espeja la regla normativa, "nunca el plan más alto"), conservando fail-open en la lectura de `plan_limits` (si no hay contra qué comparar, no bloquear). Detalle en `design.md` D5.

**OQ-4 — Usuario miembro de más de una cuenta.**
`ai-precio` hoy resuelve la cuenta con `.single()` sobre `account_members`, que **lanza error** si el usuario pertenece a 2+ cuentas. Hoy no se dispara (los 34 miembros de prod son owner de exactamente una cuenta), pero el RPC nuevo necesita una regla determinista.
**Recomendación: resolver de forma determinista y documentada** (ver `design.md` D2) y no introducir todavía el concepto de "cuenta activa" seleccionable, que pertenece al cluster `v3-rbac-multirole`.

## Out of Scope (explícito)

- **Renovación/suscripción real de MercadoPago y el webhook H-02**: es otro change ya firmado por el PO (sign-off ronda 4, 2026-07-31). No se toca acá.
- **El cron de período de gracia**: no se toca.
- **Migración de contadores de uso a `accounts`** (OQ-2).
- **Backend Python**: no consume `get_effective_plan` todavía; su alineación pertenece a `v31-authz-token-hook` (el plan viaja por el claim del token). Fuera de alcance.
- **Frontend**: ya usa el espejo TS correcto (`frontend/lib/plan-utils.ts`, actualizado por `billing-pro-trial` con `billingExempt` y sin `billingStatus`). No se toca.
