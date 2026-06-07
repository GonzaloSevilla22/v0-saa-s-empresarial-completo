## Why

El webhook de pagos MercadoPago vive en `frontend/app/api/billing/webhook/route.ts` (Next.js). Con C-16 el backend Python ya tiene la capa de datos y los 8 dominios de negocio; migrar pagos completa la separación de responsabilidades y permite que el frontend sea puramente UI. El corte se hace con **doble ejecución en paralelo** (shadow mode) para comparar resultados antes de apagar el webhook de Next.js, eliminando riesgo de pérdida de cobros.

## What Changes

- **Nuevo** `POST /payments/webhook` en FastAPI: verifica firma HMAC-SHA256 de MercadoPago, aplica idempotencia por `mercadopago_payment_id`, actualiza `accounts.billing_plan` + INSERT en `billing_events` + INSERT en `email_logs`
- **Nuevo** `backend/routers/payments.py`, `backend/services/payments.py`, `backend/schemas/payments.py`
- **Shadow mode** durante la transición: el webhook Next.js sigue activo; el nuevo endpoint FastAPI recibe las mismas notificaciones (vía configuración dual en MercadoPago) y loguea discrepancias sin efectos secundarios
- **Corte manual** (requiere aprobación humana): desactivar el webhook Next.js y apagar el shadow mode una vez validada la paridad ≥ 7 días en producción
- **Tests** de firma inválida → 400, evento duplicado → 200 idempotente, pago aprobado → plan actualizado, cancelación → downgrade al vencimiento

## Capabilities

### New Capabilities

- `payment-webhook`: Endpoint FastAPI que procesa notificaciones IPN de MercadoPago con verificación de firma, idempotencia y actualización de plan

### Modified Capabilities

- `python-backend`: Se agrega el router `/payments` al registro de routers en `main.py`

## Impact

- **Backend**: nuevos archivos `routers/payments.py`, `services/payments.py`, `schemas/payments.py`
- **`backend/main.py`**: registrar `payments.router` con prefijo `/payments`
- **MercadoPago Dashboard**: configurar segunda URL de webhook apuntando al backend FastAPI (Render) durante el shadow mode
- **Infraestructura**: variable de entorno `MERCADOPAGO_WEBHOOK_SECRET` ya en `backend/.env.example`; no requiere cambios de schema DB (mismas tablas `billing_events`, `accounts`, `email_logs`)
- **Governance CRÍTICO**: el apagado del webhook Next.js es un paso manual con aprobación humana explícita; ningún agente lo ejecuta de forma autónoma
