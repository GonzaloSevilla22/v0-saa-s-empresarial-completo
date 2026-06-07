## 1. Service-role pool

- [x] 1.1 Agregar `SUPABASE_SERVICE_ROLE_KEY` a `backend/.env.example` y documentar que solo lo usa el router de pagos
- [x] 1.2 Agregar `service_role_key: str = ""` al `Settings` en `backend/core/config.py`
- [x] 1.3 Crear `init_service_pool()` y `close_service_pool()` en `backend/core/database.py`: pool asyncpg que conecta con la service_role key (sin JWT-passthrough)
- [x] 1.4 Registrar `init_service_pool` / `close_service_pool` en el lifespan de `backend/main.py`
- [x] 1.5 Exponer `get_service_conn()` como `AsyncGenerator` usando `FastAPI.Depends` para inyectar en el router de pagos

## 2. Schema Pydantic

- [x] 2.1 Crear `backend/schemas/payments.py`:
  - `MpNotification` (type, data.id)
  - `MpPaymentData` (status, external_reference, transaction_amount, preference_id)
  - `WebhookResponse` (ok, idempotent?, shadow?, skipped?, error?)

## 3. Verificación HMAC

- [x] 3.1 Crear `backend/services/payments.py` con `verify_mp_signature(raw_body: bytes, x_signature: str | None, x_request_id: str | None, secret: str) -> bool` usando `hmac.compare_digest` — paridad exacta con la implementación Web Crypto de Next.js
- [x] 3.2 Test unitario: firma válida → True; firma inválida → False; campos faltantes → False; secret vacío → False

## 4. Lógica de negocio

- [x] 4.1 Implementar `process_payment(payment_id: str, conn, shadow: bool) -> WebhookResponse` en `backend/services/payments.py`:
  - Idempotency check: `SELECT id FROM billing_events WHERE mercadopago_payment_id = $1`
  - Fetch payment desde MercadoPago API con `httpx` (no SDK de Node — usar REST directo con `Authorization: Bearer <MP_ACCESS_TOKEN>`)
  - Parse `external_reference` formato `userId::plan`; validar contra PLAN_HIERARCHY
  - Si `shadow=True`: loguear resultado esperado, no escribir
  - UPDATE `accounts` + INSERT `billing_events` + INSERT `email_logs`
- [x] 4.2 Agregar `MERCADOPAGO_ACCESS_TOKEN` a `Settings` y a `.env.example` (distinto del webhook secret)

## 5. Router

- [x] 5.1 Crear `backend/routers/payments.py`:
  - `POST /webhook` con `Request` para leer body raw (previo a parseo), `shadow: bool = Query(False)`, `conn = Depends(get_service_conn)`
  - Extraer `x-signature` y `x-request-id` de headers
  - Llamar `verify_mp_signature`; si falla → HTTP 400
  - Parsear `MpNotification`; si `type != "payment"` → skip
  - Llamar `process_payment`
- [x] 5.2 Registrar `payments.router` en `backend/main.py` con `prefix="/payments"` y `tags=["payments"]`

## 6. Tests

- [x] 6.1 `backend/tests/test_payments.py`:
  - Pago aprobado + firma válida → HTTP 200, plan actualizado en mock DB
  - Firma inválida → HTTP 400, sin escrituras
  - `mercadopago_payment_id` duplicado → HTTP 200, `idempotent: true`, sin escrituras
  - `external_reference` inválido → HTTP 400
  - `?shadow=true` + pago aprobado → HTTP 200, `shadow: true`, sin escrituras en DB
- [x] 6.2 Verificar que `pytest backend/tests/ -v` pasa con todos los tests (C-16 + C-17)

## 7. Deploy y shadow mode (pasos manuales — requieren aprobación humana)

- [ ] 7.1 Agregar `SUPABASE_SERVICE_ROLE_KEY` y `MERCADOPAGO_ACCESS_TOKEN` como env vars en Render Dashboard
- [ ] 7.2 Configurar segunda URL de webhook en MercadoPago Dashboard apuntando a `https://<render-domain>/payments/webhook?shadow=true`
- [ ] 7.3 Monitorear logs de shadow mode durante 7 días; verificar 0 discrepancias vs webhook Next.js
- [ ] 7.4 **Con aprobación humana explícita**: cambiar URL principal de MercadoPago a FastAPI (`/payments/webhook` sin `?shadow=true`); dejar Next.js como shadow 48h adicionales
- [ ] 7.5 **Con aprobación humana explícita**: remover URL de Next.js de MercadoPago; marcar `frontend/app/api/billing/webhook/route.ts` como deprecated con comentario `// C-17: migrado a FastAPI — pendiente de borrar`
