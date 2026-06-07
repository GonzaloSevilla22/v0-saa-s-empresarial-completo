## Context

El webhook `POST /api/billing/webhook` existe en Next.js (`frontend/app/api/billing/webhook/route.ts`). Usa el SDK `mercadopago` v2, verifica firma HMAC-SHA256 con Web Crypto API, y llama a Supabase con la service_role (via `createClient()` server-side + `auth.admin.getUserById`). El schema ya tiene `billing_events`, `accounts`, `email_logs` — no se toca.

**Restricción clave**: MercadoPago envía las notificaciones sin JWT de usuario — es server-to-server. El JWT-passthrough de C-15/C-16 **no aplica aquí**; se usa `SUPABASE_SERVICE_ROLE_KEY` como excepción documentada (job administrativo aislado).

## Goals / Non-Goals

**Goals**
- Reimplementar `POST /payments/webhook` en FastAPI con paridad funcional exacta al webhook Next.js
- Shadow mode: el nuevo endpoint corre en paralelo sin efectos secundarios durante 7 días
- Rollback limpio: si la validación falla, se apaga el endpoint FastAPI sin tocar Next.js

**Non-Goals**
- Soporte a Stripe (fuera del scope de esta fase)
- Migrar los endpoints `/api/billing/cancel` y `/api/billing/preferences` (no son webhooks; permanecen en Next.js)
- Automatizar el corte — el apagado del webhook Next.js es un paso manual con aprobación humana

## Decisions

### 1. Service_role para la DB, no JWT-passthrough

**Decisión**: usar `SUPABASE_SERVICE_ROLE_KEY` en el pool asyncpg de este endpoint (o en el cliente supabase-py).

**Alternativa considerada**: crear un usuario de DB con permisos mínimos solo para billing. Descartado por complejidad operacional.

**Rationale**: La excepción al JWT-passthrough está documentada en CLAUDE.md ("jobs administrativos aislados"). Un webhook de pago entrante desde MercadoPago no tiene contexto de usuario autenticado — no hay JWT que pasar. Usar service_role aquí es seguro porque el endpoint verifica la firma HMAC antes de cualquier operación en DB.

**Implementación**: se crea un helper `get_service_pool()` en `backend/core/database.py` que conecta con `SUPABASE_SERVICE_ROLE_KEY`. Solo lo usa el router de pagos.

### 2. HMAC verification con hmac.compare_digest

**Decisión**: reimplementar la verificación de firma en Python usando `hmac` + `hashlib` de la stdlib.

**Rationale**: equivalencia exacta con la implementación Web Crypto de Next.js. `hmac.compare_digest` garantiza tiempo constante (protección timing attack).

### 3. Shadow mode vía configuración dual en MercadoPago

**Decisión**: configurar dos URLs de webhook en el Dashboard de MercadoPago:
- URL A (activa): `https://<vercel-domain>/api/billing/webhook` — procesa y tiene efecto
- URL B (shadow): `https://<render-domain>/payments/webhook?shadow=true` — procesa pero no escribe a DB, solo loguea discrepancias

**Alternativa considerada**: proxy desde Next.js al backend Python. Descartado porque añade latencia y acoplamiento.

**Flag `?shadow=true`**: cuando presente, el endpoint ejecuta toda la lógica (verificación, lookup en DB) pero no hace UPDATE/INSERT. Retorna el resultado esperado y lo loguea para comparación.

### 4. Idempotencia por mercadopago_payment_id

Se mantiene igual al Next.js: `SELECT id FROM billing_events WHERE mercadopago_payment_id = $1`. Si existe, retorna HTTP 200 sin efecto.

### 5. Email via email_logs (DEC-09)

Se mantiene el patrón: INSERT en `email_logs` → Supabase DB Webhook → Edge Function → Resend. El backend Python no llama a Resend directamente.

## Risks / Trade-offs

- **[Riesgo] MercadoPago no garantiza entrega única** → Mitigación: idempotencia por `mercadopago_payment_id` en ambos webhooks
- **[Riesgo] Divergencia entre resultados Next.js y FastAPI en shadow mode** → Mitigación: log estructurado con diff; no se hace el corte hasta 0 discrepancias en 7 días
- **[Riesgo] service_role expuesto en Render** → Mitigación: variable de entorno solo en servidor; el endpoint valida firma HMAC antes de tocar la DB
- **[Riesgo] Cold start de Render (~50s)** → Mitigación: UptimeRobot ping a `/health` cada 5 min; MercadoPago reintenta notificaciones fallidas automáticamente

## Migration Plan

1. Implementar `POST /payments/webhook` con flag `?shadow=true` funcional
2. Deploy a Render (CI ya configurado)
3. Agregar URL B (shadow) en MercadoPago Dashboard — **paso manual**
4. Monitorear logs 7 días: 0 discrepancias en comparación A vs B
5. **Con aprobación humana explícita**:
   a. Invertir roles: URL A → FastAPI (activa), URL B → Next.js (shadow)
   b. Monitorear 48h adicionales
   c. Remover URL B; marcar `POST /api/billing/webhook` como deprecated en Next.js
6. **Rollback**: eliminar URL B de MercadoPago en cualquier momento; el estado de la DB queda intacto

## Open Questions

- ¿Cuál es el dominio definitivo de Render en producción? (para configurar la URL B en MercadoPago)
- ¿El `SUPABASE_SERVICE_ROLE_KEY` ya está seteado como env var en Render, o hay que agregarlo?
