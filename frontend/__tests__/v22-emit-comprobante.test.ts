/**
 * v22-afip-delegation-billing — EmitirComprobante frontend unit tests.
 *
 * Tests pure functions only — no network, no DB, no Supabase client.
 *
 * TDD cycle:
 *   RED → GREEN → TRIANGULATE:
 *   - translateEmitError maps known backend error codes to friendly Spanish messages
 *   - isDelegationError detects the DELEGATION_NOT_AUTHORIZED sentinel
 *   - comprobanteLabel resolves the correct comprobante type per IVA condition
 *
 * Spec refs:
 *   - v22-afip-delegation-billing/design.md §"OQ-3 – emit endpoint"
 *   - D11 (PV resolver), D7 (delegation error)
 */

import { describe, it, expect } from "vitest"

// ── Duplicate pure logic from use-emit-comprobante.ts for isolated testing ────

function translateEmitError(message: string): string {
  if (
    message.includes("DELEGATION_NOT_AUTHORIZED") ||
    message.includes("Administrador de Relaciones") ||
    message.includes("representante") ||
    message.includes("aún no autorizó")
  ) {
    return "DELEGATION_NOT_AUTHORIZED: Aliadata aún no está autorizado como representante en tu cuenta ARCA. Configurá la delegación en Ajustes → Datos fiscales."
  }
  if (message.includes("ambiguous_point_of_sale"))
    return "La cuenta tiene varios puntos de venta activos. Seleccioná cuál usar."
  if (message.includes("no_active_point_of_sale"))
    return "La cuenta no tiene puntos de venta activos. Configurá uno en Datos fiscales."
  if (message.includes("fiscal_profile_not_found"))
    return "La cuenta no tiene perfil fiscal configurado. Completá los datos en Ajustes → Datos fiscales."
  if (message.includes("point_of_sale_not_found_or_inactive"))
    return "El punto de venta seleccionado no existe o está inactivo."
  return message || "Ocurrió un error inesperado al emitir el comprobante."
}

function isDelegationError(message: string): boolean {
  return message.startsWith("DELEGATION_NOT_AUTHORIZED:")
}

// ── comprobanteLabel (duplicated from EmitirComprobanteDialog) ────────────────

type IvaCondition = "responsable_inscripto" | "monotributista" | "exento" | "consumidor_final"

function comprobanteLabel(ivaCondition: IvaCondition | undefined): string {
  switch (ivaCondition) {
    case "monotributista":        return "Factura C"
    case "responsable_inscripto": return "Factura A / B"
    case "exento":                return "Factura C"
    default:                      return "Comprobante electrónico"
  }
}

// ── Tests: translateEmitError ─────────────────────────────────────────────────

describe("translateEmitError", () => {
  it("maps DELEGATION_NOT_AUTHORIZED to sentinel-prefixed friendly message", () => {
    const result = translateEmitError("DELEGATION_NOT_AUTHORIZED")
    expect(result).toContain("DELEGATION_NOT_AUTHORIZED:")
    expect(result).toContain("Aliadata")
    expect(result).toContain("ARCA")
  })

  it("maps 'Administrador de Relaciones' (backend Spanish text) to delegation message", () => {
    const result = translateEmitError(
      "La cuenta aún no autorizó al representante (Administrador de Relaciones)",
    )
    expect(result).toContain("DELEGATION_NOT_AUTHORIZED:")
  })

  it("maps ambiguous_point_of_sale to multi-PV message", () => {
    const result = translateEmitError("error: ambiguous_point_of_sale")
    expect(result).toContain("varios puntos de venta")
    expect(result).not.toContain("DELEGATION_NOT_AUTHORIZED")
  })

  it("maps no_active_point_of_sale correctly", () => {
    const result = translateEmitError("no_active_point_of_sale for account")
    expect(result).toContain("no tiene puntos de venta activos")
  })

  it("maps fiscal_profile_not_found correctly", () => {
    const result = translateEmitError("fiscal_profile_not_found")
    expect(result).toContain("perfil fiscal")
  })

  it("maps point_of_sale_not_found_or_inactive correctly", () => {
    const result = translateEmitError("point_of_sale_not_found_or_inactive")
    expect(result).toContain("no existe o está inactivo")
  })

  it("passes through unknown errors verbatim", () => {
    const msg = "some unexpected backend error XYZ"
    expect(translateEmitError(msg)).toBe(msg)
  })

  it("returns fallback for empty string", () => {
    expect(translateEmitError("")).toBe("Ocurrió un error inesperado al emitir el comprobante.")
  })
})

// ── Tests: isDelegationError ──────────────────────────────────────────────────

describe("isDelegationError", () => {
  it("returns true for DELEGATION_NOT_AUTHORIZED-prefixed message", () => {
    const translated = translateEmitError("DELEGATION_NOT_AUTHORIZED")
    expect(isDelegationError(translated)).toBe(true)
  })

  it("returns false for other translated errors", () => {
    const translated = translateEmitError("ambiguous_point_of_sale")
    expect(isDelegationError(translated)).toBe(false)
  })

  it("returns false for unknown errors", () => {
    expect(isDelegationError("some random error")).toBe(false)
  })
})

// ── Tests: comprobanteLabel ───────────────────────────────────────────────────

describe("comprobanteLabel", () => {
  it("returns 'Factura C' for monotributista", () => {
    expect(comprobanteLabel("monotributista")).toBe("Factura C")
  })

  it("returns 'Factura A / B' for responsable_inscripto", () => {
    expect(comprobanteLabel("responsable_inscripto")).toBe("Factura A / B")
  })

  it("returns 'Factura C' for exento", () => {
    expect(comprobanteLabel("exento")).toBe("Factura C")
  })

  it("returns generic label when IVA condition is undefined", () => {
    expect(comprobanteLabel(undefined)).toBe("Comprobante electrónico")
  })

  it("returns generic label for consumidor_final (edge case)", () => {
    expect(comprobanteLabel("consumidor_final")).toBe("Comprobante electrónico")
  })
})
