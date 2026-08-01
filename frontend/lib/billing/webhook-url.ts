/**
 * Backend webhook URL — single source of truth (D3, v31-mp-upgrade-webhook-fix).
 *
 * Both `app/api/billing/preferences/route.ts` (the `notification_url` baked
 * into every MercadoPago preference at creation time) and the legacy
 * `app/api/billing/webhook/route.ts` forwarder (the relay target for
 * preferences created before this change) read the backend's webhook
 * endpoint from here. Two separate constants for the same destination is a
 * guaranteed source of drift between environments — this file is the only
 * place that concatenates `/payments/webhook`.
 *
 * Deliberately does NOT import `@/lib/mercadopago` — that module pulls in
 * the `mercadopago` SDK at module scope, which the legacy forwarder must
 * not depend on (D1: the forwarder has no MercadoPago SDK access left).
 *
 * Fail-closed: throws if `NEXT_PUBLIC_BACKEND_URL` is unset. Callers MUST
 * catch this and respond with an explicit error — falling back to a default
 * would emit a preference / relay that notifies nothing, silently
 * reproducing H-02 (payment captured, plan never accredited).
 */
export function getBackendWebhookUrl(): string {
  const backendUrl = process.env.NEXT_PUBLIC_BACKEND_URL
  if (!backendUrl) {
    throw new Error('NEXT_PUBLIC_BACKEND_URL is not set')
  }
  return `${backendUrl.replace(/\/+$/, '')}/payments/webhook`
}
