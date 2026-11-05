## Why

El 2026-11-04 MercadoPago cobró la cuota de noviembre ($24.900) de la única suscripción real (`subscriptions.id fa624f9b-32e5-4b5c-ad0d-fc64e6dc16b1`, preapproval `50681db010a341968e53c3880d52c3e9`, cuenta Aliadata Perfumes, plan Inicial) y el plan **no se extendió**: el backend acredita el cobro SÓLO cuando llega la notificación `subscription_authorized_payment` en estado `processed`/`approved`, y esa notificación **nunca se emitió** (historial de notificaciones de MP de la app ALIADATA: en el mes, 1 `payment` + 1 `subscription_authorized_payment` en `scheduled`, 0 fallidas, 0 pendientes). La notificación `payment` del mismo cobro (187789722328) sí llegó dos veces y se ignoró por diseño (`ignored="subscription_charge"`, ítem B(1) de #526). El PO lo reparó a mano el 2026-11-05 16:37 UTC con "Replicar cuotas" en `/admin/pagos/ambiguas`, que hizo exactamente lo que el sistema debió hacer solo. Con un cobro mensual por cliente, depender de una notificación que MercadoPago no garantiza deja a cada abonado a 10 días de perder un plan ya pagado.

## What Changes

- **Núcleo de reconciliación compartido**: el cuerpo de `replay_subscription_charges` (consultar `GET /preapproval/{id}` + `GET /authorized_payments/search` y acreditar cada cuota `processed`/`approved` vía `_apply_approved_charge`) se extrae a una función de servicio única que consumen tres caminos: el replay admin (sin cambio de contrato), un barrido programado y el webhook `payment`. Cero lógica de acreditación nueva.
- **Barrido programado (red principal)**: `pg_cron` cada hora llama, vía `pg_net` y el mismo patrón de secreto compartido del relay fiscal, a un endpoint de máquina nuevo `POST /payments/subscriptions/reconcile-cron` que reconcilia las suscripciones autorizadas cuyo período pagado ya llegó a su fecha de cobro sin que se acreditara el cobro del ciclo. Detrás de la palanca existente `billing_subscriptions_enabled`.
- **Webhook `payment` como acelerador**: cuando un `payment` aprobado de un cobro de suscripción trae `metadata.preapproval_id` de una suscripción conocida, en vez de sólo ignorarlo se reconcilia ESE preapproval en el momento. Sin ese dato, se sigue reconociendo con 200 sin escrituras (el barrido lo cubre).
- **Corrección de un defecto latente del replay que el barrido amplificaría**: hoy el replay reaplica TODAS las cuotas aprobadas con el vencimiento del ciclo vigente del preapproval; si MercadoPago adelanta `next_payment_date` antes de procesar la cuota nueva, reaplicar la cuota vieja extendería el plan sin cobro. El vencimiento pasa a moverse SÓLO por una cuota que se acredita por primera vez.
- **Serialización por suscripción**: la acreditación toma un lock transaccional por preapproval para que barrido, webhook y replay concurrentes no dupliquen el correo de renovación.
- **Observabilidad**: el backend no configura logging de aplicación (no hay `basicConfig`), así que toda línea `logger.info` de `backend.*` se descarta en Render — por eso no se sabe qué marcador detectó el pago 187789722328. Se configura el nivel INFO para los loggers `backend.*` y la línea del marcador incluye el preapproval resuelto.
- **Superficie admin mínima**: la tabla "Suscripciones recientes" de `/admin/pagos/ambiguas` muestra el vencimiento del plan de la cuenta y la fecha del último cobro acreditado, para ver de un vistazo si el mes entró. "Replicar cuotas" sigue siendo la red manual.

## Capabilities

### New Capabilities

(ninguna)

### Modified Capabilities

- `subscription-lifecycle`: se agrega la acreditación por reconciliación (barrido programado) independiente de la notificación de la cuota, la regla de que reconciliar nunca extiende el período por un cobro ya acreditado, y la visibilidad del último cobro acreditado en el panel admin.
- `payment-webhook`: el requirement "A subscription charge's payment notification is acknowledged, not rejected" cambia — un `payment` de suscripción con `metadata.preapproval_id` conocido dispara la reconciliación de ese preapproval (ya no es "sin escrituras" en ese caso); se agrega el endpoint de máquina del barrido con autenticación por secreto compartido.

## Impact

- **Backend**: `backend/services/subscriptions.py` (extracción del núcleo, regla de vencimiento, barrido), `backend/services/payments.py` (rama del marcador), `backend/repositories/subscriptions_repository.py` (consulta de suscripciones vencidas; `list_recent_subscriptions` con dos columnas), `backend/routers/payments.py` (endpoint de cron), `backend/core/` (dependencia reutilizable de secreto compartido, extraída del inline de `backend/routers/fiscal.py`), `backend/main.py` (logging).
- **DB**: una migración `20261092000001_mp_cuota_reconciliacion_cron.sql` (número a re-verificar al aplicar): función `SECURITY DEFINER` disparadora (lee `backend_base_url`/`cae_relay_secret` de Vault, como `rpc_trigger_cae_relay`) + job `pg_cron` horario. Sin cambios de tablas.
- **Frontend**: `frontend/app/(dashboard)/admin/pagos/ambiguas/page.tsx` + `frontend/hooks/data/use-ambiguous-subscriptions.ts` (dos columnas en una tabla existente; ruta y menú ya existen). Desktop + mobile, tema claro y oscuro.
- **Prod**: sin pasos manuales nuevos si se reutiliza el secreto del relay (OQ-2); el barrido toca la API de MercadoPago sólo para suscripciones vencidas (hoy, 1).
- **Governance CRÍTICO** (webhook de pagos, dinero real): el apply espera sign-off explícito del PO.
