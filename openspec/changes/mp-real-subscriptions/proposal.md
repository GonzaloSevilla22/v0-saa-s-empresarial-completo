# mp-real-subscriptions — Suscripciones recurrentes reales de MercadoPago

> **Governance: CRÍTICO (dinero real).** Sign-off del PO del 2026-07-31 sobre el rumbo
> (engram `bugs/mp-subscription-renewal`, obs #517): migrar a la **API de Suscripciones real
> de MercadoPago** (`preapproval_plan` + `preapproval` + webhook
> `subscription_authorized_payment` + dunning), con `v31-mp-upgrade-webhook-fix` (H-02)
> **primero como prerequisito**. El PO eligió deliberadamente la opción de mayor esfuerzo
> por sobre un modelo de renovación manual: quiere la solución definitiva. Este change
> **materializa** esa decisión; no la reabre.
>
> **Depende de**: `v31-mp-upgrade-webhook-fix` cerrado y verificado (Fase 3: un pago real
> acreditó solo). Sin ese canal sano, nada de lo de acá llega a la base de datos.

## Why

**La recurrencia nunca existió.** El flujo de upgrade crea una `Preference` de Checkout Pro
—un **pago único**— y al acreditarlo pone `plan_expires_at = NULL`
(`backend/services/payments.py:168`). El resultado es un plan pago **eterno**: se cobra una
vez y el acceso no vence nunca. No hay segundo cobro, no hay aviso de vencimiento, no hay
downgrade por impago. El único cliente pagador lleva un mes y medio con plan PRO sin que se
le haya vuelto a cobrar, porque no hay nada que lo cobre.

Las piezas que parecen cubrirlo, no lo cubren:
- `process_cancellations()` (C-10) **sí** degrada, pero solo cuentas en
  `billing_status='cancelling'` — un estado al que solo se llega si el usuario cancela a
  mano. Un impago nunca lo alcanza.
- `expire_trials()` fue realineado a `accounts` por `billing-pro-trial` (migración
  `20260817000001`), pero solo mueve `trialing → expired`, y su propio `COMMENT` lo declara
  **descriptivo, no autoritativo**. No toca planes pagos.
- `get_effective_plan()` —la definición normativa del plan efectivo— **no lee
  `plan_expires_at` en absoluto**. Su precedencia es exención → trial vigente →
  `billing_plan` → `gratis`. Un `billing_plan='pro'` vencido sigue devolviendo `pro`.

Es decir: el vencimiento de un plan pago no está representado en el único lugar que decide
el acceso.

## What Changes

- **El upgrade crea una suscripción, no un pago único.** Se reemplaza la `Preference` por el
  par `preapproval_plan` (un plan mensual por tier pago, creado una vez y reutilizable) +
  `preapproval` (la suscripción de una cuenta a ese plan). El usuario autoriza el débito
  recurrente una sola vez y MercadoPago cobra todos los meses.

- **BREAKING: la creación del checkout se muda al backend FastAPI.** Un endpoint nuevo
  `POST /payments/subscriptions` reemplaza a `/api/billing/preferences`. El motivo es
  estructural: crear una suscripción **exige persistir** el `preapproval_id` para poder
  correlacionar los cobros mensuales que van a llegar después, y escribir desde una route
  de Next.js con cliente anónimo es exactamente lo que causó H-02. `v31-mp-upgrade-webhook-fix`
  dejó esta puerta abierta a propósito.

- **BREAKING: la cancelación cancela la suscripción en MercadoPago.** Hoy
  `/api/billing/cancel` solo escribe `billing_status='cancelling'` y una fecha inventada de
  30 días. Pasa a cancelar el `preapproval` en MP (que es lo que efectivamente detiene el
  cobro) y a programar la degradación al fin del período **realmente pagado**.

- **Ciclo de vida persistido**: tabla nueva `public.subscriptions` con `preapproval_id`,
  plan, estado, fecha del próximo cobro y estado de reintento. Como máximo una suscripción
  viva por cuenta, garantizado por índice único parcial.

- **`plan_expires_at` pasa a ser un dato real** derivado de `next_payment_date` del
  `preapproval` más un período de gracia, en vez de `NULL` o de una fecha inventada.

- **`get_effective_plan()` gana un término de vencimiento**: un `billing_plan` pago con
  `plan_expires_at` **en el pasado** deja de otorgar ese plan. La firma de un solo parámetro
  **no cambia** (queda congelada; se redefine el cuerpo con `CREATE OR REPLACE` sobre la
  misma firma, sin crear overload) y la precedencia existente —exención → trial → plan— se
  conserva intacta.

- **Downgrade por impago reutilizando la lógica que ya existe**: cuando MercadoPago cancela
  la suscripción por cobros fallidos, la cuenta entra en el circuito de
  `process_cancellations()` que ya está en producción. **No se duplica** ese barrido.

- **Dunning en dos canales**: aviso por la campana (evento al outbox → Consumer 4, mismo
  patrón que `PlanLimitExceeded`) y por email (`email_logs`, con `event_type` nuevos), tanto
  antes del vencimiento como al fallar un cobro.

- **Corrección obligatoria de la verificación de firma**: para las notificaciones de
  suscripción el `data.id` sale del **query param** de la URL y **debe pasarse a minúsculas
  si es alfanumérico** (los IDs de `preapproval` lo son). La implementación actual lo lee del
  cuerpo y no normaliza — funciona solo porque los IDs de pago son numéricos. Sin este fix,
  **todas** las notificaciones de suscripción fallan la firma. Hallazgo heredado de
  `v31-mp-upgrade-webhook-fix` D7.

- **Migración de la cuenta pagadora actual** (`danielsevilla64`) con la decisión ya firmada:
  30 días desde la activación del sistema nuevo, el mes y medio transcurrido queda de
  cortesía. Coordinado con el PO, sin cobro automático retroactivo.

- **Fuera de alcance**: cobro anual (`price_ars_annual` ya existe en `plan_limits` pero el
  alcance firmado es mensual); prorrateo en cambios de plan a mitad de ciclo; atomicidad
  transaccional del webhook (**H-19 / `v31-mp-webhook-atomic`**); reintentos propios de
  cobro (MercadoPago ya hace hasta 4 en 10 días y cancela tras 3 cuotas rechazadas
  consecutivas — no se reimplementa).

## Capabilities

### New Capabilities

- `subscription-lifecycle`: el ciclo de vida completo de una suscripción recurrente —
  creación del plan y de la suscripción, estados y sus transiciones, cobro mensual
  autorizado, dunning por cobro fallido, cancelación y degradación por impago, y la
  persistencia que correlaciona todo eso con una cuenta.

### Modified Capabilities

- `payment-gateway`: el flujo de upgrade deja de crear una preferencia de pago único y pasa
  a crear una suscripción; la cancelación pasa a cancelar el `preapproval` en MercadoPago.
- `payment-webhook`: el endpoint suma los topics `subscription_preapproval` y
  `subscription_authorized_payment`, y corrige la derivación del `data.id` firmado.
- `billing-trial-lifecycle`: `get_effective_plan()` incorpora el vencimiento del plan pago a
  su precedencia, conservando firma y orden de precedencia actuales.
- `billing`: `plan_expires_at` pasa de "fecha de cancelación programada" a "fin del período
  efectivamente pagado", con semántica definida para el valor nulo.
- `in-app-notifications`: nuevo tipo de notificación para el cobro fallido, siguiendo el
  patrón ya establecido por `PlanLimitExceeded`.
- `billing-ui`: `/facturacion` muestra el estado real de la suscripción (próximo cobro,
  estado, reintentos en curso) en vez de una fecha estimada.

## Impact

**Base de datos** (migraciones idempotentes, numeradas desde `20260829000001`)
- Tabla nueva `public.subscriptions` + RLS + índice único parcial de "una viva por cuenta".
- `public.get_effective_plan(uuid)` redefinida con `CREATE OR REPLACE` sobre la **misma
  firma**, con `REVOKE` explícito de `PUBLIC`, `anon` **y** `authenticated` y `GRANT` a
  `supabase_auth_admin` y `service_role` **en el mismo archivo**.
- `operation_idempotency`: `operation_kind` nuevo para las notificaciones de suscripción
  (recreando el CHECK con la **unión vigente en producción** — lección C3).
- Funciones nuevas del productor de eventos de dunning + tipo nuevo en
  `_notification_from_event` (misma firma, sin overload).

**Backend**
- `backend/routers/payments.py`, `backend/services/payments.py`, `backend/schemas/payments.py`
- Repositorio nuevo para `subscriptions`; endpoints de alta y cancelación de suscripción.

**Frontend**
- `frontend/components/billing/PlanComparison.tsx`, `CancelSubscriptionModal.tsx`,
  `/facturacion`, `/planes`.
- `frontend/app/api/billing/preferences/route.ts` y `cancel/route.ts` se retiran o quedan
  como redirecciones al backend.

**Edge Functions**
- `supabase/functions/send-email/index.ts`: plantillas para los `event_type` nuevos.

**Configuración** (sin secretos en el repo, todo [MANUAL PO])
- Credenciales de test/sandbox de MercadoPago.
- Registro de los topics de suscripción en el panel de webhooks de MP.

**Riesgo principal**: es el único camino por el que entra dinero. Todo se valida primero en
sandbox; ningún test toca dinero real.
