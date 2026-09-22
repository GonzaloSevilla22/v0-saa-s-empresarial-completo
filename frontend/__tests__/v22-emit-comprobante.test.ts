/**
 * v22-afip-delegation-billing — EmitirComprobante frontend unit tests.
 *
 * Tests pure functions only — no network, no DB, no Supabase client.
 * translateEmitError / isDelegationError are imported from the real hook
 * module (frontend/hooks/data/use-emit-comprobante.ts) — these tests exercise
 * production logic, not a copy of it.
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
 *   - fiscal-riesgos-residuales R4 (client_not_found — client no pertenece al tenant)
 */

import { describe, it, expect, vi } from "vitest"

// use-emit-comprobante.ts imports `pythonClient`, which throws at module load
// if NEXT_PUBLIC_BACKEND_URL isn't set (see lib/api/python-client.ts). These
// tests only exercise the pure translateEmitError/isDelegationError exports,
// so the client is mocked minimally — same pattern as
// __tests__/hooks/use-expenses-payment-method.test.ts.
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  },
}))

import { translateEmitError, isDelegationError } from "@/hooks/data/use-emit-comprobante"

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

  it("maps client_not_found to a tenancy-friendly message", () => {
    const result = translateEmitError(
      "client_not_found: el cliente no existe o no pertenece a la cuenta",
    )
    expect(result).not.toContain("client_not_found")
    expect(result).toContain("no pertenece a tu cuenta")
  })

  it("maps client_not_found with only the token + a uuid suffix", () => {
    const result = translateEmitError("client_not_found: 3f2c1a90-6b7d-4e21-9c3a-8f1a2b3c4d5e")
    expect(result).not.toContain("client_not_found")
    expect(result).toContain("no pertenece a tu cuenta")
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

  it("returns false for the translated client_not_found message", () => {
    const translated = translateEmitError(
      "client_not_found: el cliente no existe o no pertenece a la cuenta",
    )
    expect(isDelegationError(translated)).toBe(false)
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
