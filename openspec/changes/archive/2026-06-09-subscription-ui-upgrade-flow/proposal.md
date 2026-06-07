## Why

El sistema de planes está definido en la DB (C-01) y las restricciones están activas (C-02/C-03), pero no hay forma de que un usuario pague para subir de plan. Sin pasarela de pagos, el modelo freemium es estructuralmente incompleto: los usuarios llegan al límite, ven el CTA, y no tienen dónde ir. Este change cierra ese loop de monetización.

## What Changes

- **Nueva page `/planes`**: comparativo visual de los 4 planes con precios, features y CTA de upgrade
- **Integración MercadoPago Checkout Pro**: flujo de pago para Argentina (ARS) con preferencia de pago via API
- **API route `/api/billing/webhook`**: recibe confirmación de pago de MercadoPago, verifica firma, actualiza `organizations.plan` + `billing_events`
- **API route `/api/billing/cancel`**: inicia cancelación de suscripción, degrada plan al vencimiento del período pagado
- **Nueva page `/facturacion`**: historial de pagos, plan actual, botones de cambio/cancelación
- **Emails transaccionales**: `plan_upgraded` y `plan_downgraded` via patrón INSERT en `email_logs`
- **Webhook de cancelación MercadoPago**: degrada el plan cuando el período pagado vence (no inmediatamente)
- **Componente `<PlanCard />`**: reutilizable en `/planes` y en modales de upgrade inline

## Capabilities

### New Capabilities

- `payment-gateway`: Integración MercadoPago Checkout Pro — creación de preferencias de pago, verificación de firmas HMAC en webhooks, manejo de estados de pago (approved/pending/rejected/cancelled)
- `billing-ui`: Páginas de planes y facturación — `/planes` con comparativo visual, `/facturacion` con historial de pagos y gestión de suscripción activa

### Modified Capabilities

- `billing`: Agregar lógica de procesamiento de pagos reales — UPDATE de `organizations.plan` desde webhook verificado, INSERT en `billing_events` con proof de pago, nueva columna `billing_subscription_id` ya existe (C-01), agregar `mercadopago_payment_id TEXT` y `mercadopago_preference_id TEXT` a `billing_events`
- `trial-lifecycle`: El webhook de downgrade voluntario y el email `plan_downgraded` extienden el lifecycle de facturación (actualmente solo maneja expiración automática)

## Impact

- **Nuevas API routes**: `app/api/billing/webhook/route.ts`, `app/api/billing/preferences/route.ts`, `app/api/billing/cancel/route.ts`
- **Nuevas páginas**: `app/(dashboard)/planes/page.tsx`, `app/(dashboard)/facturacion/page.tsx`
- **Nuevos componentes**: `components/billing/PlanCard.tsx`, `components/billing/PlanComparison.tsx`, `components/billing/BillingHistory.tsx`
- **Edge Function** `send-email`: agregar templates `plan_upgraded` y `plan_downgraded`
- **Variables de entorno requeridas**: `MERCADOPAGO_ACCESS_TOKEN`, `MERCADOPAGO_WEBHOOK_SECRET`, `NEXT_PUBLIC_APP_URL`
- **Dependencia externa**: SDK MercadoPago (`@mercadopago/sdk-js` client, `mercadopago` server)
- **DB**: INSERT en `billing_events` desde webhook — requiere `service_role` en la API route (no desde cliente)
