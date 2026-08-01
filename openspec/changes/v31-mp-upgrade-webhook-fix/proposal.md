# v31-mp-upgrade-webhook-fix — Reconexión del webhook de upgrade (H-02)

> **Governance: CRÍTICO (dinero real).** Sign-off del PO dado el 2026-07-31 sobre el rumbo
> (engram `bugs/mp-subscription-renewal`, obs #517): *"v31-mp-upgrade-webhook-fix (H-02)
> PRIMERO como prerequisito — este es su sign-off explícito"*. Este change **materializa**
> esa decisión; no la reabre. Los pasos que tocan dinero real (pago E2E, panel de MP,
> retiro del legacy) quedan marcados como **[MANUAL PO]** y no se ejecutan sin su
> confirmación explícita.

## Why

Ningún pago de MercadoPago acredita el plan solo. La `notification_url` que se hornea en
cada preferencia apunta a `frontend/app/api/billing/webhook/route.ts`, un route handler de
Next.js que verifica bien la firma HMAC pero después escribe con un **cliente Supabase
anónimo con cookies del request** — y un webhook servidor-a-servidor de MercadoPago no
trae cookies. La RLS de producción bloquea el `UPDATE accounts` y el `INSERT
billing_events`, así que el handler devuelve 200 a MP (que da la notificación por
entregada y deja de reintentar) mientras la cuenta sigue en el plan viejo. El único pago
real cobrado (`$69.900`, junio 2026) hubo que reconciliarlo a mano.

El webhook **correcto ya existe y está desplegado**: `POST /payments/webhook` en el backend
FastAPI (C-17) — misma verificación HMAC, misma idempotencia por
`mercadopago_payment_id`, escribe con conexión de servicio y ya trae un modo `?shadow=true`
pensado exactamente para esta migración. Lo único que falta es que MercadoPago le hable.

Es **prerequisito duro de `mp-real-subscriptions`**: no tiene sentido construir el ciclo de
vida de suscripciones reales (cobros mensuales, dunning, downgrade por impago) sobre un
canal de notificaciones que no llega a la base de datos.

## What Changes

- **La `notification_url` de las preferencias nuevas apunta al backend.**
  `frontend/app/api/billing/preferences/route.ts` pasa a emitir
  `${NEXT_PUBLIC_BACKEND_URL}/payments/webhook` en vez de `${appUrl}/api/billing/webhook`.
  Fail-closed: si `NEXT_PUBLIC_BACKEND_URL` no está definida, la creación de la preferencia
  falla con 500 en vez de crear una preferencia que notifique al vacío.

- **BREAKING (interno): el route handler legacy de Next.js deja de escribir en la base y
  pasa a ser un *forwarder* sin estado.** Recibe la notificación, la reenvía **cruda**
  (bytes del body + `x-signature` + `x-request-id`, sin re-serializar — cualquier
  normalización rompería el HMAC) al webhook del backend, y propaga su código de estado.
  Esto no es cosmético: **MercadoPago hornea la `notification_url` dentro de la preferencia
  en el momento de crearla**, así que toda preferencia ya emitida —incluido un checkout que
  un usuario dejó abierto ayer y paga pasado mañana— va a seguir golpeando la URL vieja
  para siempre. Borrar el route en vez de convertirlo en forwarder tiraría esos pagos al
  piso. El forwarder es lo que cierra H-02 para el tráfico viejo **y** el nuevo.

- **Ventana de convivencia con comparación de resultados** (regla dura del proyecto para
  el webhook de pagos). Durante la ventana conviven las dos rutas de entrada — legacy
  (forwarder) y directa — y ambas terminan en el mismo endpoint del backend, que ya es
  idempotente por `mercadopago_payment_id`: si una notificación llegara por las dos, la
  segunda es un no-op verificable. El forwarder registra cada relay con el estado que
  devolvió el backend, y `billing_events` es la evidencia de acreditación. El corte se
  decide con datos, no por calendario.

- **Retiro del legacy diferido y condicionado** [MANUAL PO]: el forwarder se elimina solo
  cuando (a) el pago E2E de verificación acreditó solo, y (b) el forwarder registró cero
  relays durante la ventana acordada. Hasta entonces se queda como red de seguridad barata.

- **Verificación del secreto HMAC de Render** [MANUAL PO]: confirmar que
  `MERCADOPAGO_WEBHOOK_SECRET` está seteada en el servicio de Render **y que es la misma
  cadena** configurada en el panel de MP (*Tus integraciones → Webhooks*). Se verifica por
  presencia y por un pago de prueba que valide firma — **nunca imprimiendo ni comparando el
  valor**. Si el secreto no coincide, el backend rechaza todo con 400 y el síntoma es
  idéntico al bug actual (pago cobrado, plan sin acreditar).

- **Fuera de alcance, explícito**: la atomicidad del webhook (transacción envolvente +
  lookup determinista) es **H-19 / `v31-mp-webhook-atomic`**, un change P1 propio. Acá no
  se toca `process_payment` más allá de lo necesario para recibir el tráfico. Tampoco se
  toca `/api/billing/cancel` (sigue siendo el camino de cancelación hasta que
  `mp-real-subscriptions` lo reemplace por la cancelación de `preapproval`).

## Capabilities

### New Capabilities

_Ninguna._ Este change reconecta infraestructura que ya existe; no introduce un dominio
nuevo.

### Modified Capabilities

- `payment-gateway`: el requirement *"Verificar y procesar webhook de pago"* afirma hoy que
  `/api/billing/webhook` actualiza el plan del usuario — eso deja de ser cierto y además
  nunca funcionó en producción. Pasa a: la ruta de Next.js reenvía al backend sin escribir,
  y la preferencia declara la `notification_url` del backend.
- `payment-webhook`: `POST /payments/webhook` queda declarado como **el único sistema de
  registro** de la acreditación de pagos, y debe procesar de forma equivalente las
  notificaciones que llegan directas de MercadoPago y las reenviadas por el forwarder.

## Impact

**Código**
- `frontend/app/api/billing/preferences/route.ts` — `notification_url` + guard fail-closed.
- `frontend/app/api/billing/webhook/route.ts` — de handler con escrituras a forwarder sin
  estado (se va el cliente Supabase, la lógica de plan, el `email_logs`).
- `frontend/__tests__/billing.test.ts` — cobertura de la URL emitida y del forwarder.
- `backend/routers/payments.py` / `backend/services/payments.py` — sin cambios de lógica de
  negocio; a lo sumo trazas para distinguir origen directo vs. reenviado.
- `backend/tests/test_payments.py` — casos de equivalencia directo/reenviado.

**Configuración** (sin secretos en el repo)
- Vercel: `NEXT_PUBLIC_BACKEND_URL` ya existe (la usa `frontend/lib/api/python-client.ts` y
  el `connect-src` del CSP en `frontend/lib/supabase/middleware.ts`) — solo hay que
  confirmar que está poblada en producción.
- Render: `MERCADOPAGO_WEBHOOK_SECRET` y `MERCADOPAGO_ACCESS_TOKEN` [MANUAL PO].
- Panel de MercadoPago: URL de notificaciones y secreto [MANUAL PO].

**Datos**
- Sin migraciones. Ninguna tabla cambia de forma. La evidencia de que funciona son filas
  nuevas en `billing_events` (`event_type='plan_upgraded'`) y en `email_logs`.

**Riesgo**
- Cold start de Render (~50s en free tier): MercadoPago reintenta las notificaciones
  fallidas, y el endpoint es idempotente, así que un 502 por arranque en frío se recupera
  solo. Se cubre en design.
- El único cliente pagador vive en la cuenta `danielsevilla64`; su migración de ciclo de
  vida es de `mp-real-subscriptions`, no de este change.

**Depende de**: nada. **Desbloquea**: `mp-real-subscriptions`.
