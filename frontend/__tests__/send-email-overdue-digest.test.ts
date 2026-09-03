/**
 * cobranzas-vencimientos (grupo 6) — plantilla del resumen diario de deuda
 * vencida del Edge Function send-email.
 *
 * Mismo patrón D5/D6 que send-email-fanout-policy.test.ts: importa el módulo
 * REAL `supabase/functions/_shared/overdue-digest-template.ts` (puro, sin
 * `Deno.*` a nivel módulo) por ruta relativa, en vez de re-declarar la regla
 * dentro del test.
 *
 * Task 6.1 (RED): el cuerpo renderiza cantidad de partes, importe vencido y
 * el acceso a /cobranzas, tomados de metadata.
 * Task 6.3 (TRIANGULATE): textos distintos por lado; metadata incompleta no
 * rompe el armado (el genérico del index.ts cubre los event_type
 * desconocidos — acá se fija que el builder no explota con datos pobres).
 *
 * Run: pnpm vitest run __tests__/send-email-overdue-digest.test.ts
 */

import { describe, it, expect } from "vitest"
import { buildOverdueDigestContent } from "../../supabase/functions/_shared/overdue-digest-template"

const APP_URL = "https://app.aliadata.test"

describe("buildOverdueDigestContent — lado por cobrar (task 6.1)", () => {
  const content = buildOverdueDigestContent(
    "receivables",
    { party_count: 3, overdue_total: 45000, as_of: "2026-09-02" },
    APP_URL,
  )

  it("renderiza la cantidad de partes con deuda vencida", () => {
    expect(content.bodyHtml).toContain("3")
    expect(content.bodyHtml.toLowerCase()).toContain("cliente")
  })

  it("renderiza el importe vencido formateado en pesos", () => {
    // toLocaleString es-AR: 45.000 (separador de miles con punto)
    expect(content.bodyHtml).toContain("45.000")
    expect(content.bodyHtml).toContain("$")
  })

  it("ofrece el acceso directo a /cobranzas", () => {
    expect(content.ctaUrl).toBe(`${APP_URL}/cobranzas`)
    expect(content.ctaText.length).toBeGreaterThan(0)
  })

  it("el título habla de deuda por cobrar", () => {
    expect(content.title.toLowerCase()).toContain("cobrar")
  })
})

describe("buildOverdueDigestContent — lado por pagar (task 6.3: texto propio)", () => {
  const content = buildOverdueDigestContent(
    "payables",
    { party_count: 1, overdue_total: 800, as_of: "2026-09-02" },
    APP_URL,
  )

  it("habla de proveedores, no de clientes", () => {
    expect(content.title.toLowerCase()).toContain("proveedor")
    expect(content.bodyHtml.toLowerCase()).toContain("proveedor")
    expect(content.bodyHtml.toLowerCase()).not.toContain("cliente")
  })

  it("renderiza cantidad e importe del lado proveedor", () => {
    expect(content.bodyHtml).toContain("1")
    expect(content.bodyHtml).toContain("800")
  })

  it("también apunta a /cobranzas (la pestaña Por pagar vive ahí)", () => {
    expect(content.ctaUrl).toBe(`${APP_URL}/cobranzas`)
  })
})

describe("buildOverdueDigestContent — robustez (task 6.3)", () => {
  it("singular: 1 cliente no dice 'clientes'", () => {
    const content = buildOverdueDigestContent(
      "receivables",
      { party_count: 1, overdue_total: 100, as_of: "2026-09-02" },
      APP_URL,
    )
    expect(content.bodyHtml).toMatch(/1 cliente\b/)
  })

  it("metadata incompleta no rompe el armado (degrada a texto genérico)", () => {
    const content = buildOverdueDigestContent("receivables", {}, APP_URL)
    expect(content.title.length).toBeGreaterThan(0)
    expect(content.ctaUrl).toBe(`${APP_URL}/cobranzas`)
    // sin importe conocido, no inventa un "$ undefined"
    expect(content.bodyHtml).not.toContain("undefined")
    expect(content.bodyHtml).not.toContain("NaN")
  })

  it("importes que llegan como string (jsonb) también se formatean", () => {
    const content = buildOverdueDigestContent(
      "receivables",
      { party_count: "2", overdue_total: "7000.00", as_of: "2026-09-02" },
      APP_URL,
    )
    expect(content.bodyHtml).toContain("7.000")
  })
})
