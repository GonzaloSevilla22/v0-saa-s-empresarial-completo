/**
 * Backend webhook URL — single source of truth (D3, v31-mp-upgrade-webhook-fix).
 *
 * `app/api/billing/preferences/route.ts` reads the backend's webhook
 * endpoint from here to bake it into every MercadoPago preference's
 * `notification_url` at creation time. A separate constant for the same
 * destination is a guaranteed source of drift between environments — this
 * file is the only place that concatenates `/payments/webhook`.
 *
 * The legacy `app/api/billing/webhook/route.ts` forwarder (the relay target
 * for preferences created before v31-mp-upgrade-webhook-fix) was the other
 * consumer of this helper; it was retired once the 30-day convivencia
 * window closed with zero relayed traffic (verified 2026-09-08 — see
 * `v31-mp-upgrade-webhook-fix` task 6.3). MercadoPago now notifies
 * `POST /payments/webhook` on the backend directly for every preference.
 *
 * Deliberately does NOT import `@/lib/mercadopago` — that module pulls in
 * the `mercadopago` SDK at module scope, and this helper must stay usable
 * from routes that have no reason to load that SDK just to resolve a URL.
 *
 * Fail-closed: throws if `NEXT_PUBLIC_BACKEND_URL` is unset. Callers MUST
 * catch this and respond with an explicit error — falling back to a default
 * would emit a preference that notifies nothing, silently reproducing H-02
 * (payment captured, plan never accredited).
 */
export function getBackendWebhookUrl(): string {
  const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL
  if (!backendUrl) {
    throw new Error('NEXT_PUBLIC_BACKEND_URL is not set')
  }
  return `${backendUrl.replace(/\/+$/, '')}/payments/webhook`
}
