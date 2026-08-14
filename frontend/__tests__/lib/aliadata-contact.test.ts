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
import {
  aliadataWhatsAppUrl,
  ALIADATA_WHATSAPP_MESSAGE,
  ALIADATA_WHATSAPP_MESSAGE_EMPRESA,
} from "@/lib/aliadata-contact"

const CANONICAL = "5492617635174"
const VALID_PHONE = "+54 9 2617 63-5174"

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

// ── Mensaje por superficie (D4, plan-empresa-contacto) ────────────────────────
// El tier Empresa es el segundo consumidor que necesita un mensaje propio (el
// primero, FAB+footer, comparte ALIADATA_WHATSAPP_MESSAGE). En vez de una
// tercera función que arma la URL a mano, el helper acepta un segundo
// parámetro opcional con el mensaje general como default.
describe("aliadataWhatsAppUrl — mensaje por superficie", () => {
  // ── RED/GREEN: mensaje propio del tier Empresa viaja en el enlace ─────────
  it("builds the URL with the tier's own message when provided", () => {
    const url = aliadataWhatsAppUrl(VALID_PHONE, ALIADATA_WHATSAPP_MESSAGE_EMPRESA) as string
    expect(url).toContain(`https://wa.me/${CANONICAL}`)
    expect(new URL(url).searchParams.get("text")).toBe(ALIADATA_WHATSAPP_MESSAGE_EMPRESA)
  })

  // ── TRIANGULATE (a): sin segundo parámetro, no-regresión de FAB y footer ──
  it("falls back to the general message when no second argument is given", () => {
    const url = aliadataWhatsAppUrl(VALID_PHONE) as string
    expect(new URL(url).searchParams.get("text")).toBe(ALIADATA_WHATSAPP_MESSAGE)
  })

  // ── TRIANGULATE (b): el mensaje del tier es distinto del general ──────────
  it("the tier message differs from the general channel message", () => {
    expect(ALIADATA_WHATSAPP_MESSAGE_EMPRESA).not.toBe(ALIADATA_WHATSAPP_MESSAGE)
  })

  // ── TRIANGULATE (c): número inválido con mensaje propio sigue devolviendo
  // null — la validación previa del número no se saltea por el nuevo parámetro
  it("returns null with an invalid phone even when a tier message is given", () => {
    expect(aliadataWhatsAppUrl("123", ALIADATA_WHATSAPP_MESSAGE_EMPRESA)).toBeNull()
    expect(aliadataWhatsAppUrl(undefined, ALIADATA_WHATSAPP_MESSAGE_EMPRESA)).toBeNull()
  })

  // ── TRIANGULATE (d): emoji y espacios viajan percent-encoded ───────────────
  it("percent-encodes the emoji and spaces of the tier message", () => {
    const url = aliadataWhatsAppUrl(VALID_PHONE, ALIADATA_WHATSAPP_MESSAGE_EMPRESA) as string
    expect(url).not.toMatch(/\s/)
    expect(url).not.toContain("👋")
    expect(url).toContain(encodeURIComponent(ALIADATA_WHATSAPP_MESSAGE_EMPRESA))
  })
})
