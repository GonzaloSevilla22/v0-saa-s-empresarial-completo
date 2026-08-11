/**
 * Tests para `lib/aliadata-contact.ts` — helper canónico del contacto por
 * WhatsApp de ALIADATA (número normalizado + mensaje inicial estándar).
 *
 * Nace al sumar el segundo consumidor del canal (link "Contacto" del footer,
 * además del FAB): la regla del repo es que lo reusable vive en `lib/`, y
 * tener UNA función que arma la URL garantiza que ambas superficies apunten
 * al mismo destino con el mismo mensaje.
 *
 * Ciclo: RED (el módulo no existe) → GREEN → TRIANGULATE.
 */

import { describe, it, expect } from "vitest"
import { aliadataWhatsAppUrl, ALIADATA_WHATSAPP_MESSAGE } from "@/lib/aliadata-contact"

const CANONICAL = "5492617635174"

describe("aliadataWhatsAppUrl", () => {
  // ── RED/GREEN: número real en formato internacional ───────────────────────
  it("builds the wa.me URL for the real ALIADATA number", () => {
    const url = aliadataWhatsAppUrl("+54 9 2617 63-5174")
    expect(url).toContain(`https://wa.me/${CANONICAL}`)
  })

  // ── TRIANGULATE: formato local → mismo destino canónico ───────────────────
  it("normalizes a local format to the same canonical URL", () => {
    expect(aliadataWhatsAppUrl("0261 763-5174")).toBe(aliadataWhatsAppUrl("+54 9 2617 63-5174"))
  })

  // ── TRIANGULATE: el mensaje estándar viaja codificado ─────────────────────
  it("embeds the standard message URL-encoded", () => {
    const url = aliadataWhatsAppUrl("+54 9 2617 63-5174") as string
    expect(url).not.toMatch(/\s/)
    expect(new URL(url).searchParams.get("text")).toBe(ALIADATA_WHATSAPP_MESSAGE)
  })

  // ── TRIANGULATE: degradación — null antes que un enlace sin destino ───────
  // `buildWhatsAppUrl` con teléfono inválido cae a `wa.me/?text=…` (selector
  // de contactos): correcto en su contexto original, bug de cara al público.
  // Por eso este helper valida ANTES y devuelve null.
  it.each([
    ["undefined", undefined],
    ["null", null],
    ["empty", ""],
    ["blank", "   "],
    ["not normalizable", "123"],
  ])("returns null when the phone is %s", (_label, phone) => {
    expect(aliadataWhatsAppUrl(phone)).toBeNull()
  })
})
