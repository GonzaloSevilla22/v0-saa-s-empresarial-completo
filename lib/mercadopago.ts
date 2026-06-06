/**
 * MercadoPago SDK singleton — server-side only (C-10 subscription-ui-upgrade-flow)
 *
 * Import this module ONLY in server-side code (API routes, Server Actions).
 * NEVER import in Client Components — this file must remain server-only to
 * avoid leaking MERCADOPAGO_ACCESS_TOKEN to the browser bundle.
 *
 * Usage:
 *   import { mp, Preference } from '@/lib/mercadopago'
 *   const pref = new Preference(mp)
 *   const { id } = await pref.create({ body: { items: [...], back_urls: {...} } })
 */

import MercadoPago from 'mercadopago'
import { Preference, Payment } from 'mercadopago'

const accessToken = process.env.MERCADOPAGO_ACCESS_TOKEN

if (!accessToken) {
  // Throw at module load time so the misconfiguration surfaces immediately
  // in local dev. In production this is caught by Vercel's env check.
  throw new Error(
    '[mercadopago] MERCADOPAGO_ACCESS_TOKEN is not set. ' +
    'Add it to your .env.local (dev) or Vercel environment variables (prod).'
  )
}

/** Singleton MercadoPago client — reused across requests in the same process. */
export const mp = new MercadoPago({ accessToken })

/** Re-export resource classes for convenience so callers don't need to import from 'mercadopago' directly. */
export { Preference, Payment }
