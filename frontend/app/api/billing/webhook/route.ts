/**
 * POST /api/billing/webhook
 *
 * LEGACY stateless forwarder (v31-mp-upgrade-webhook-fix, D1/D2).
 *
 * MercadoPago bakes `notification_url` into a preference at the moment it
 * is created, and that value can never be changed afterward. Every
 * preference issued before this change keeps notifying THIS URL for the
 * rest of its useful life (a checkout left open yesterday and paid the day
 * after tomorrow still lands here). Deleting this route instead of turning
 * it into a forwarder would drop that traffic on the floor.
 *
 * This route no longer verifies the MercadoPago signature, reads Supabase,
 * or updates the plan (H-02: it used to write with an anonymous client +
 * request cookies, which RLS silently rejected — 0 rows updated, HTTP 200
 * returned anyway, MercadoPago considered the notification delivered).
 * All of that now lives exactly once in the backend
 * (`POST /payments/webhook`, see payment-webhook spec): it re-verifies the
 * signature, checks idempotency, and is the sole writer of
 * `accounts.billing_plan` / `billing_events`.
 *
 * Rule (D2): relay raw bytes, never JSON.parse -> JSON.stringify. Any
 * re-serialization (key order, unicode escapes, whitespace) can change what
 * the backend's HMAC verification sees and silently break the signature.
 *
 * C-10 subscription-ui-upgrade-flow / v31-mp-upgrade-webhook-fix
 */

import { NextResponse } from 'next/server'
import { getBackendWebhookUrl } from '@/lib/billing/webhook-url'

// Next.js App Router: disable body parsing so we can read raw bytes.
export const runtime = 'nodejs'

export async function POST(req: Request): Promise<NextResponse> {
  let backendWebhookUrl: string
  try {
    backendWebhookUrl = getBackendWebhookUrl()
  } catch {
    console.error(
      '[billing/webhook] NEXT_PUBLIC_BACKEND_URL is not set — refusing to relay (fail-closed)'
    )
    return NextResponse.json({ ok: false, error: 'Backend no configurado' }, { status: 500 })
  }

  // Raw bytes only — never JSON.parse + JSON.stringify (D2).
  const rawBody = await req.text()
  const xSignature = req.headers.get('x-signature')
  const xRequestId = req.headers.get('x-request-id')

  // x-relay-source: origin marker for the backend's traceability requirement
  // (payment-webhook spec — "Notification origin is observable"). Safe under
  // D2: it is not part of the HMAC-signed template (id + x-request-id + ts),
  // so adding it cannot change what the backend's signature check sees.
  const headers: Record<string, string> = {
    'content-type': 'application/json',
    'x-relay-source': 'legacy-frontend',
  }
  if (xSignature) headers['x-signature'] = xSignature
  if (xRequestId) headers['x-request-id'] = xRequestId

  let backendResponse: Response
  try {
    backendResponse = await fetch(backendWebhookUrl, {
      method: 'POST',
      headers,
      body: rawBody,
    })
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error)
    console.error('[billing/webhook] Relay to backend failed:', message)
    return NextResponse.json({ ok: false, error: 'Error al reenviar al backend' }, { status: 502 })
  }

  const responseBody = await backendResponse.text()

  // Relay trace (payment-gateway spec: "Cada reenvío queda trazado") — only
  // the notification id + the backend's status, best-effort parse for the
  // log line only. The signature/secret verification, and any risk of
  // leaking them, lives entirely in the backend; this route never sees them.
  let paymentId = 'unknown'
  try {
    const parsed = JSON.parse(rawBody) as { data?: { id?: string } }
    paymentId = parsed?.data?.id ?? 'unknown'
  } catch {
    // Best-effort only — the relay above already went out with the
    // original bytes untouched regardless of whether this parse succeeds.
  }
  console.log(
    `[billing/webhook] Relayed payment ${paymentId} — backend responded ${backendResponse.status}`
  )

  return new NextResponse(responseBody, {
    status: backendResponse.status,
    headers: { 'content-type': backendResponse.headers.get('content-type') ?? 'application/json' },
  })
}
