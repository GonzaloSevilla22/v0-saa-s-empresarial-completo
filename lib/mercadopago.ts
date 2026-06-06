/**
 * MercadoPago SDK singleton — server-side only (C-10 subscription-ui-upgrade-flow)
 *
 * Import this module ONLY in server-side code (API routes, Server Actions).
 * NEVER import in Client Components — this file must remain server-only to
 * avoid leaking MERCADOPAGO_ACCESS_TOKEN to the browser bundle.
 *
 * Usage:
 *   import { getMp, Preference } from '@/lib/mercadopago'
 *   const pref = new Preference(getMp())
 *   const { id } = await pref.create({ body: { items: [...], back_urls: {...} } })
 */

import MercadoPago from 'mercadopago'
import { Preference, Payment } from 'mercadopago'

// Lazy singleton: initialized on first request, not at import time.
// This avoids crashing next build when MERCADOPAGO_ACCESS_TOKEN is not set
// as a build-time env var in Vercel (it only needs to exist at runtime).
let _mp: MercadoPago | null = null

export function getMp(): MercadoPago {
  if (_mp) return _mp

  const accessToken = process.env.MERCADOPAGO_ACCESS_TOKEN
  if (!accessToken) {
    throw new Error(
      '[mercadopago] MERCADOPAGO_ACCESS_TOKEN is not set. ' +
      'Add it to your .env.local (dev) or Vercel environment variables (prod).'
    )
  }

  _mp = new MercadoPago({ accessToken })
  return _mp
}

/** Re-export resource classes for convenience so callers don't need to import from 'mercadopago' directly. */
export { Preference, Payment }
