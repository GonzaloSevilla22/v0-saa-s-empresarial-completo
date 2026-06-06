## Context

C-01 definió el schema de billing (4 planes, `billing_events`, `billing_subscription_id`). C-02 puso los límites activos en producción. C-03 implementó el trial de 30 días con downgrade automático. El CTA de upgrade ya existe en la UI, pero apunta a `/planes` que todavía no existe. Este change cierra el loop: usuario ve el límite → va a `/planes` → paga → el sistema activa el plan.

La pasarela elegida es **MercadoPago Checkout Pro** (ver Decisión 1). El flujo es: frontend crea una preferencia via API route → redirige a MP hosted → MP envía webhook al servidor → servidor verifica y actualiza el plan.

## Goals / Non-Goals

**Goals:**
- Page `/planes` con comparativo visual de los 4 planes y CTA de compra
- Integración MercadoPago Checkout Pro: crear preferencia de pago server-side
- Webhook `/api/billing/webhook` que verifica firma HMAC y actualiza plan
- Page `/facturacion`: plan actual, historial de `billing_events`, botón de cancelar
- Emails `plan_upgraded` y `plan_downgraded` via patrón `email_logs`
- Gating: usuarios en `billing_status = 'expired'` solo ven plan `gratis`

**Non-Goals:**
- Suscripciones recurrentes automáticas (MercadoPago Subscriptions API) — implementar como pagos anuales manuales en MVP; recurrencia automática es V2
- Facturación electrónica AFIP — fuera de scope (ver DEC-04)
- Soporte multi-moneda / Stripe — solo ARS / MercadoPago en este change
- Portal de admin para gestionar planes manualmente — ya existe en `/admin`

## Decisions

### Decisión 1 — MercadoPago Checkout Pro (no Stripe, no Bricks)

**MercadoPago sobre Stripe**: el público target es Argentina. MP acepta tarjetas locales (Visa Débito, Maestro, Cabal, Naranja), transferencias bancarias, Mercado Crédito y billeteras digitales en ARS sin conversión. Stripe requiere cuenta USA o registro complejo; MP tiene integración directa para entidades argentinas.

**Checkout Pro (hosted) sobre Bricks (embedded)**: Checkout Pro redirige a una página hosteada por MP. Ventajas: MP maneja toda la UI de pago, cumple con PCI DSS sin esfuerzo propio, no requiere capturar datos de tarjeta en nuestro frontend. Trade-off: el usuario sale de la app brevemente. Aceptable para MVP.

**Pagos one-shot sobre Subscriptions API**: La API de Subscriptions de MP tiene mayor complejidad de configuración (planes, facturas, webhooks de renovación). En MVP, implementamos pagos únicos (anuales o mensuales manuales) con `billing_subscription_id` como referencia del `payment_id`. El usuario renueva manualmente. V2 puede agregar recurrencia.

### Decisión 2 — API Routes Next.js para webhook (no Edge Functions Supabase)

El webhook de MP necesita verificar firma HMAC con `MERCADOPAGO_WEBHOOK_SECRET` y luego hacer un UPDATE con `service_role`. Las API Routes de Next.js en Vercel:
- Tienen acceso a `process.env` con las secrets
- Retornan 200 rápido (MP reintenta si tarda > 5s)
- No están limitadas por el 50ms CPU de Edge Runtime

Trade-off: no son Deno — usar `mercadopago` npm SDK (Node.js), no el SDK de Deno.

### Decisión 3 — Estado de suscripción en billing_events (event log)

En lugar de actualizar solo `organizations.plan`, cada cambio de plan inserta en `billing_events`:
```
event_type: 'plan_upgraded' | 'plan_downgraded' | 'payment_received' | 'payment_failed'
from_plan: texto
to_plan: texto
mercadopago_payment_id: texto (ID del pago en MP)
mercadopago_preference_id: texto (ID de la preferencia generada)
amount: numeric
metadata: jsonb (payload completo del webhook, para debug)
```
Esto da auditoría completa y permite reconstruir el estado del plan desde el log si hay inconsistencias.

### Decisión 4 — Columnas adicionales en billing_events

Agregar `mercadopago_payment_id TEXT` y `mercadopago_preference_id TEXT` a `billing_events`. La columna `billing_subscription_id` en `organizations` (C-01) se usa para guardar el `payment_id` del último pago aprobado, que sirve para verificar vigencia.

### Decisión 5 — Precios en la DB (plan_limits) no hardcodeados

La tabla `plan_limits` (C-01) ya tiene los límites. Agregar columna `price_ars_monthly NUMERIC` y `price_ars_annual NUMERIC` a `plan_limits` para que los precios se lean de la DB y sean actualizables sin deploy. Lectura pública (RLS ya configurado en C-01).

## Risks / Trade-offs

- **[Risk] Webhook llega antes que el usuario regresa** → No es problema: el webhook actualiza el plan en DB; cuando el usuario llega a `/planes/success` el plan ya está activo. La página de éxito hace un refetch del perfil.
- **[Risk] Webhook falso (sin verificar firma)** → Mitigación: siempre verificar `x-signature` header con HMAC-SHA256 usando `MERCADOPAGO_WEBHOOK_SECRET`. Rechazar con 401 si no coincide.
- **[Risk] Doble webhook (MP puede enviar el mismo evento 2 veces)** → Mitigación: idempotencia en webhook handler — verificar que `mercadopago_payment_id` no exista ya en `billing_events` antes de actualizar plan.
- **[Risk] Sandbox vs Producción** → MP tiene entornos separados con credenciales distintas. `MERCADOPAGO_ACCESS_TOKEN` empieza con `TEST-` en sandbox y `APP_USR-` en producción. El handler debe validar esto en staging.
- **[Risk] Precios en ARS se desactualizan rápido (inflación)** → Decisión 5 resuelve esto: precios en DB, actualizables sin deploy.

## Migration Plan

1. Agregar columnas a `billing_events`: `mercadopago_payment_id`, `mercadopago_preference_id`, `amount`
2. Agregar columnas a `plan_limits`: `price_ars_monthly`, `price_ars_annual`; seed con los precios de RN-03
3. Instalar `mercadopago` SDK: `pnpm add mercadopago`
4. Implementar API routes (webhook, preferences, cancel)
5. Implementar pages `/planes` y `/facturacion`
6. Configurar webhook URL en MercadoPago Dashboard (paso manual — ver guía de conexión)
7. Variables de entorno en Vercel: `MERCADOPAGO_ACCESS_TOKEN`, `MERCADOPAGO_WEBHOOK_SECRET`

**Rollback**: si el webhook falla en producción, el plan del usuario no cambia (el pago ya ocurrió en MP). El admin puede actualizar `organizations.plan` manualmente desde `/admin` mientras se investiga. No hay datos perdidos.

## Open Questions

- PA-02: ¿el botón "Cancelar suscripción" en `/facturacion` degrada inmediatamente o al vencer el período pagado? → Decisión propuesta: degradar al vencimiento del período (comportamiento estándar de SaaS). El campo `plan_expires_at` debe existir en `organizations`.
- ¿Los planes se ofrecen monthly, annual, o ambos en el MVP? → Propuesta: solo mensual en MVP para simplificar. Annual en V2 cuando haya métricas de retención.
