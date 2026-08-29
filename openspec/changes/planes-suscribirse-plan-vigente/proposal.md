## Why

El 2026-08-29 la cuenta pagadora real (`danielsevilla64`, `billing_plan='pro'` + `billing_status='active'` + `plan_expires_at` futuro por una cortesía) quiso contratar la suscripción PRO real de MercadoPago y **`/planes` no le ofreció ningún botón**: la columna PRO figuraba como "Plan actual" con el CTA deshabilitado. El PO tuvo que pasarle a mano el `init_point` crudo del `preapproval_plan`; al no existir una `subscription_intent` previa, la reconciliación automática de `mp-real-subscriptions` no tuvo con qué matchear y la suscripción cayó a la **cola de ambiguos** (`status='ambiguous'`, resolución manual por admin).

El hueco no es del backend. `create_subscription_intent()` (`backend/services/subscriptions.py` L85-87) rechaza con 409 **únicamente** si ya hay una suscripción viva (`find_live_subscription`, `status IN ('pending','authorized')`); **no** rechaza contratar el mismo tier que ya es el plan efectivo de la cuenta. El gap es 100% de la superficie frontend: `PlanCard` deshabilita el CTA cuando `plan === currentPlan` y `PlanComparison.handleSelect` hace `return` temprano en ese mismo caso — y `currentPlan` es el plan **efectivo** (`getEffectivePlan`), que incluye cortesías, trials y planes pagos por vencer. Es decir: la UI usa "tenés acceso a este tier" como si significara "ya lo estás pagando", y esas dos cosas no son lo mismo.

Con la palanca `BILLING_SUBSCRIPTIONS_ENABLED=true` ya encendida en producción y 32+ trials venciendo a fin de agosto, cada cuenta que caiga en este estado (trial vigente del tier que quiere contratar, cortesía, plan pago por vencer) se queda sin camino de pago propio y su dinero entra por la puerta de atrás. Regla de producto del PO (2026-08-02): todo lo operable necesita superficie frontend.

## What Changes

- **`/planes` distingue "plan efectivo" de "suscripción viva".** La página pasa a leer, además del plan efectivo, si la cuenta tiene una fila viva en `public.subscriptions` (`status IN ('pending','authorized')`) — la misma lectura que `/facturacion` ya hace hoy (`app/(dashboard)/facturacion/page.tsx` L138-145), extraída a un helper compartido en la capa canónica en vez de duplicada.
- **Sin suscripción viva, el tier que ya es el plan efectivo ofrece CTA de contratación.** El botón deja de estar deshabilitado y usa el **flujo normal existente** — `createSubscription()` → crea la `subscription_intent` → redirige al `init_point` — de modo que la reconciliación automática funcione y no vuelva a producirse una fila ambigua. La tarjeta sigue mostrando el badge "Plan actual" (la información de acceso no se pierde); lo que cambia es que además ofrece una acción.
- **Con suscripción viva, el comportamiento actual se conserva**: el tier vigente no ofrece CTA de contratación. Es el caso que el backend rechazaría con 409 y no tiene sentido ofrecerlo.
- **Las cuentas `billing_exempt=true` no ven ningún CTA de pago** en el comparativo (16 cuentas exentas permanentes desde el 2026-08-29). Hoy no solo ven el CTA de PRO deshabilitado sino que los tiers inferiores les ofrecen un botón **habilitado** que dispara una contratación real.
- **El CTA de "bajar de plan" deja de disparar una contratación silenciosa.** Hallazgo de la investigación: `handleSelect` no distingue downgrade de upgrade — "Cancelar y bajar a Inicial" hoy llama `createSubscription('inicial')` y redirige al checkout de Inicial, o, si hay suscripción viva, revienta con el `detail` crudo del 409 (`"Ya existe una suscripción viva para esta cuenta"`) en un toast. Se corrige el desajuste entre lo que el botón dice y lo que hace.
- **Sin cambios de backend, de base de datos, ni de contrato de API.** Se consumen `POST /payments/subscriptions` y la tabla `public.subscriptions` tal como existen hoy.

**No incluye** (Non-Goals): tocar `mp-real-subscriptions` (change activo, 55/77 — este change es una extensión de UX **sobre** su superficie, no lo pisa); cambiar la precedencia de `get_effective_plan`; implementar el cambio de tier con suscripción viva (upgrade/downgrade in-place en MercadoPago); resolver la cola de ambiguos.

## Capabilities

### New Capabilities

Ninguna. El cambio es de comportamiento de una superficie ya especificada.

### Modified Capabilities

- `billing-ui`: el requirement "Page /planes con comparativo visual de planes" hoy fija que el plan actual muestra "Tu plan actual" **en lugar de** el botón de contratar, y que el CTA de un tier inferior está deshabilitado o linkea a `/facturacion`. Ambos escenarios cambian: el discriminante del CTA pasa a ser la **existencia de una suscripción viva**, no la igualdad con el plan efectivo, y se suma el caso de cuenta exenta.

## Impact

**Frontend (única superficie afectada)**

- `frontend/app/(dashboard)/planes/page.tsx` — Server Component: suma la lectura de suscripción viva y de `billing_exempt` al set de props que pasa al comparativo.
- `frontend/components/billing/PlanComparison.tsx` — recibe el nuevo estado; `handleSelect` deja de cortar por `plan === currentPlan`.
- `frontend/components/billing/PlanCard.tsx` — el `disabled` y el `ctaLabel` dejan de derivarse solo de `isCurrent`.
- `frontend/lib/billing/` — helper nuevo (capa canónica) para la lectura de suscripción viva, reusado por `/planes` y `/facturacion`.
- Tests: `frontend/__tests__/PlanComparison.test.tsx` (existente, se extiende), más casos de `PlanCard`.

**Superficie frontend (regla PO 2026-08-02)**: pantalla `/planes`, ruta ya existente, alcanzable desde la sidebar y desde el botón "Cambiar plan" / "Ver planes disponibles" de `/facturacion`. Verificación obligatoria en desktop y mobile, y en tema claro y oscuro.

**Sin cambios**: `backend/` (verificado: `create_subscription_intent` ya admite el caso), `supabase/migrations/`, Edge Functions, `plan_limits`, `get_effective_plan`.

**Governance: MEDIUM.** Es UI de billing: no toca el webhook de MercadoPago, no mueve dinero, no escribe en `accounts`, `billing_events` ni `subscriptions`, y no altera ninguna decisión de acceso (`get_effective_plan` queda intacta). Lo que sí hace es **abrir un camino de pago que hoy está cerrado**, así que el riesgo real es ofrecer una contratación donde el backend la rechazaría (409) o donde el usuario no la quiere (exento). Ese riesgo se contiene con checkpoints explícitos y demo al PO antes del merge, no con sign-off previo.

**Hallazgo lateral registrado (fuera de scope, ver design.md)**: el espejo TypeScript `getEffectivePlan` (`frontend/lib/plan-utils.ts`) **no lee `plan_expires_at`**, mientras que la definición normativa SQL (`20260829000001`, D6 de `mp-real-subscriptions`) sí degrada a `gratis` cuando el plan pago está vencido. El test de paridad (`frontend/__tests__/plan-utils.test.ts`) no cubre ese eje, así que la divergencia no la detecta ningún gate.
