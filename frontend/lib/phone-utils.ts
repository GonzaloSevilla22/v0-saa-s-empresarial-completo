/**
 * phone-utils.ts
 *
 * Utilities for normalising Argentine phone numbers to the E.164-like format
 * required by WhatsApp deep links (wa.me/<number>?text=…).
 *
 * Argentina specifics
 * -------------------
 *  • Country code : 54
 *  • Mobile prefix for WhatsApp deep links: 549 (Meta requires the 9 after the
 *    country code for Argentine mobile numbers)
 *  • Area codes   : 2–4 digits (e.g. Buenos Aires city = 11, Mendoza = 261)
 *  • Local number : 6–8 digits after area code
 *  • Common input formats a user might type:
 *      +54 9 261 555-1234   → already international mobile  → 5492615551234
 *      +54 261 555-1234     → international without 9       → 5492615551234
 *      0261 555-1234        → local with 0 prefix           → 5492615551234
 *      261 555-1234         → local without 0               → 5492615551234
 *      011 5555-1234        → Buenos Aires local mobile     → 54911 55551234
 *      15 5555-1234         → INCOMPLETE — cannot normalise reliably
 *      5491155551234        → already correct               → 5491155551234
 */

// ── Core normaliser ───────────────────────────────────────────────────────────

/**
 * Strips formatting from a raw phone string and returns the canonical
 * WhatsApp number string (digits only, starting with 549…) used in
 * `wa.me/<number>` links.
 *
 * Returns `null` if the input is empty or cannot be reliably normalised to a
 * valid Argentine mobile number.
 */
export function normalizeWhatsAppPhone(raw: string | null | undefined): string | null {
  if (!raw?.trim()) return null

  // Keep only digits
  let d = raw.replace(/\D/g, "")

  if (d.length < 8) return null // Clearly incomplete

  // ── Already has full international prefix ──────────────────────────────────
  if (d.startsWith("549") && d.length === 13) return d   // Perfect: +54 9 XXX XXXXXXXX
  if (d.startsWith("549") && d.length >= 12)  return d.slice(0, 13) // Trim extra digits

  if (d.startsWith("54") && !d.startsWith("549")) {
    // Has country code but missing mobile "9" → insert it
    const local = d.slice(2)   // Strip country code
    return "549" + local
  }

  // ── Local Argentine formats ────────────────────────────────────────────────

  // Strip leading 0 (trunk prefix used in local dialing: 0261…, 011…)
  if (d.startsWith("0")) d = d.slice(1)

  // Strip mobile prefix "9" if it immediately follows the trunk zero
  // (e.g. "09 261 555-1234" → "92615551234" → strip the leading 9)
  // Only strip if the result still has a plausible length
  if (d.startsWith("9") && d.length === 11) d = d.slice(1)

  // At this point we should have 10 digits: [area_code][number]
  if (d.length === 10) return "549" + d
  if (d.length === 9)  return "549" + d  // Some shorter area-code combos

  // Anything else: return null rather than producing a wrong number
  return null
}

// ── Validation ────────────────────────────────────────────────────────────────

/**
 * Returns true if the raw phone string can be normalised to a WhatsApp link.
 * Use this for form-level hints (not hard errors — the user may have a valid
 * number in an unexpected format).
 */
export function isValidWhatsAppPhone(raw: string | null | undefined): boolean {
  return normalizeWhatsAppPhone(raw) !== null
}

/**
 * Human-readable hint for the form field describing the expected format.
 */
export const PHONE_FORMAT_HINT =
  "Ej: 0261 555-1234 o +54 9 261 555-1234 (para enviar comprobantes por WhatsApp)"

// ── URL builder ───────────────────────────────────────────────────────────────

/**
 * Builds a `wa.me` deep-link URL pre-loaded with `text`.
 *
 * - If `phone` normalises successfully → `https://wa.me/<number>?text=…`
 *   Opens a WhatsApp conversation directly with the client.
 * - Fallback (no phone / invalid) → `https://wa.me/?text=…`
 *   Opens WhatsApp contact picker so the user can choose manually.
 */
export function buildWhatsAppUrl(
  phone: string | null | undefined,
  text: string,
): string {
  const encoded = encodeURIComponent(text)
  const clean   = normalizeWhatsAppPhone(phone)
  return clean
    ? `https://wa.me/${clean}?text=${encoded}`
    : `https://wa.me/?text=${encoded}`
}

/**
 * Returns a display-friendly version of the normalised number,
 * or the raw string if normalisation fails.
 * Example: "5492615551234" → "+54 9 261 555-1234"
 */
export function formatPhoneDisplay(raw: string | null | undefined): string {
  if (!raw) return ""
  const n = normalizeWhatsAppPhone(raw)
  if (!n) return raw

  // n is always "549XXXXXXXXXX" (13 digits) or similar
  // Format as: +54 9 XXX XXX-XXXX (best effort)
  const rest = n.slice(3) // Remove "549"
  if (rest.length === 10) {
    // Area code 3 digits + 7-digit number
    return `+54 9 ${rest.slice(0, 3)} ${rest.slice(3, 6)}-${rest.slice(6)}`
  }
  if (rest.length === 9) {
    // Area code 2 digits (e.g. Buenos Aires 11) + 8-digit number
    return `+54 9 ${rest.slice(0, 2)} ${rest.slice(2, 6)}-${rest.slice(6)}`
  }
  // Fallback: just add + and country code
  return `+${n}`
}
