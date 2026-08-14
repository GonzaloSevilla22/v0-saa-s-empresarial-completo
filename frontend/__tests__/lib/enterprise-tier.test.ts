/**
 * Tests para `lib/enterprise-tier.ts` — contenido canónico del tier Empresa
 * (change `plan-empresa-contacto`, design.md D1).
 *
 * El tier Empresa es una oferta de CONTACTO, no un `Plan` de facturación:
 * vive fuera de `PLAN_LIMITS` a propósito (D1). El bloque de "guardia" (D8)
 * es el que convierte ese límite en algo que el CI rompe si alguien intenta
 * meter Empresa al catálogo de billing, en vez de una frase en un documento.
 *
 * Ciclo: RED (el módulo no existe) → GREEN → TRIANGULATE (guardia D8).
 */

import { describe, it, expect } from "vitest"
import { ENTERPRISE_TIER } from "@/lib/enterprise-tier"
import { PLAN_LIMITS } from "@/lib/constants"

describe("ENTERPRISE_TIER", () => {
  // ── RED/GREEN: contenido mínimo del tier ───────────────────────────────────
  it("expone nombre, precio de display, tagline, features y CTA", () => {
    expect(ENTERPRISE_TIER.name).toBe("Empresa")
    expect(ENTERPRISE_TIER.priceDisplay).toMatch(/medida/i)
    expect(ENTERPRISE_TIER.priceDisplay).not.toMatch(/\d/) // sin importe numérico
    expect(ENTERPRISE_TIER.tagline.toLowerCase()).toContain("adapta")
    expect(ENTERPRISE_TIER.features.length).toBeGreaterThanOrEqual(4)
    expect(ENTERPRISE_TIER.ctaLabel.length).toBeGreaterThan(0)
  })

  it("las features son texto no vacío", () => {
    for (const feature of ENTERPRISE_TIER.features) {
      expect(typeof feature).toBe("string")
      expect(feature.trim().length).toBeGreaterThan(0)
    }
  })
})

// ── TRIANGULATE — Test de guardia (D8) ─────────────────────────────────────
// Rompe el CI si alguien "completa" el catálogo de billing agregando Empresa
// a PLAN_LIMITS, en vez de dejarlo como una frase en el proposal.
describe("ENTERPRISE_TIER — guardia contra la contaminación de billing (D8)", () => {
  it("PLAN_LIMITS sigue teniendo exactamente las 4 claves conocidas", () => {
    expect(Object.keys(PLAN_LIMITS).sort()).toEqual(["avanzado", "gratis", "inicial", "pro"].sort())
  })

  it('"empresa" no es clave de PLAN_LIMITS', () => {
    expect(Object.keys(PLAN_LIMITS)).not.toContain("empresa")
  })

  it("el name del tier no coincide con ningún PLAN_LIMITS[k].name", () => {
    const planNames = Object.values(PLAN_LIMITS).map((p) => p.name)
    expect(planNames).not.toContain(ENTERPRISE_TIER.name)
  })
})
