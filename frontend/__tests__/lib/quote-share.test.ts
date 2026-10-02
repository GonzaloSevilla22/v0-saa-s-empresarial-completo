/**
 * presupuestos-modulo (D9, task 4.4) — `buildQuoteShareText`: el texto corto que
 * acompaña al PDF cuando se manda el presupuesto por WhatsApp.
 */
import { describe, it, expect } from "vitest"
import { buildQuoteShareText } from "@/lib/quote-share"
import { formatMoney } from "@/lib/format"

describe("buildQuoteShareText", () => {
  const base = {
    numberLabel: "P-00000012",
    total: 12345,
    validUntil: "2026-10-14",
    businessName: "Kiosco Lola",
  }

  it("con nombre, total, validez y negocio", () => {
    const text = buildQuoteShareText({ ...base, clientName: "Ana" })
    expect(text).toBe(
      `Hola Ana, te envío el presupuesto P-00000012 por ${formatMoney(12345)}, válido hasta el 14/10/2026. Kiosco Lola`,
    )
  })

  it("sin nombre del cliente: sin saludo personalizado", () => {
    const text = buildQuoteShareText({ ...base, clientName: null })
    expect(text.startsWith("Hola, te envío el presupuesto P-00000012")).toBe(true)
    expect(text).not.toContain("null")
  })

  it("un nombre en blanco cuenta como ausente", () => {
    expect(buildQuoteShareText({ ...base, clientName: "   " }).startsWith("Hola, te envío")).toBe(true)
  })

  it("sin validez: la cláusula se omite entera", () => {
    const text = buildQuoteShareText({ ...base, clientName: "Ana", validUntil: null })
    expect(text).toBe(`Hola Ana, te envío el presupuesto P-00000012 por ${formatMoney(12345)}. Kiosco Lola`)
    expect(text).not.toContain("válido")
  })

  it("sin negocio: no deja un punto ni un espacio colgando", () => {
    const text = buildQuoteShareText({ ...base, clientName: "Ana", businessName: undefined })
    expect(text.endsWith("14/10/2026.")).toBe(true)
    expect(text.endsWith(" ")).toBe(false)
  })

  it("el total se formatea como importe en pesos con separadores", () => {
    const text = buildQuoteShareText({ ...base, clientName: "Ana", total: 1234567.5 })
    expect(text).toContain(formatMoney(1234567.5))
  })

  it("la fecha se arma desde el texto ISO sin pasar por Date (sin corrimiento de día)", () => {
    expect(buildQuoteShareText({ ...base, clientName: "Ana", validUntil: "2026-01-01" })).toContain("01/01/2026")
    expect(buildQuoteShareText({ ...base, clientName: "Ana", validUntil: "2026-12-31" })).toContain("31/12/2026")
  })
})
