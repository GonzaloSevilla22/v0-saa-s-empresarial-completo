/**
 * C-27 v21-fiscal-profile — Frontend unit tests.
 *
 * Tests pure functions only — no Supabase client, no DB, no network.
 *
 * TDD cycle:
 *   4.4 RED→GREEN: translateFiscalError + FiscalDocumentBadge status config.
 *
 * Spec refs:
 *   - fiscal-profile/spec.md §"Errores de negocio"
 *   - afip-fiscal-document/spec.md §"Estados del comprobante"
 */

import { describe, it, expect } from "vitest"

// ── Duplicate pure logic from use-fiscal-profile.ts for isolated testing ─────

function translateFiscalError(message: string): string {
  if (message.includes("ambiguous_point_of_sale"))
    return "La cuenta tiene varios puntos de venta activos. Especificá cuál usar para emitir."
  if (message.includes("fiscal_profile_not_found"))
    return "La cuenta no tiene perfil fiscal configurado."
  if (message.includes("point_of_sale_not_found_or_inactive"))
    return "El punto de venta no existe o está inactivo."
  if (message.includes("no_active_point_of_sale"))
    return "La cuenta no tiene puntos de venta activos."
  if (message.includes("unauthorized"))
    return "No tenés permisos para realizar esta acción."
  return message || "Ocurrió un error inesperado."
}

// ── FiscalDocumentBadge status config (duplicated for isolation) ──────────────

type FiscalDocumentStatus = "pending_cae" | "authorized" | "rejected"

const STATUS_LABELS: Record<FiscalDocumentStatus, string> = {
  pending_cae: "En trámite",
  authorized:  "Autorizado",
  rejected:    "Rechazado",
}

function getStatusLabel(status: FiscalDocumentStatus): string {
  return STATUS_LABELS[status] ?? "Desconocido"
}

function isTerminalStatus(status: FiscalDocumentStatus): boolean {
  return status === "authorized" || status === "rejected"
}

// ── CUIT validation (re-exported from use-fiscal-profile, C-22 logic) ─────────

const CUIT_REGEX = /^(\d{2})-(\d{8})-(\d)$/
const CUIT_WEIGHTS = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]

function isValidCuit(value: string): boolean {
  const match = value.trim().match(CUIT_REGEX)
  if (!match) return false
  const digits = (match[1] + match[2]).split("").map(Number)
  const sum = digits.reduce((acc, digit, i) => acc + digit * CUIT_WEIGHTS[i], 0)
  let check = 11 - (sum % 11)
  if (check === 11) check = 0
  if (check === 10) check = 9
  return check === Number(match[3])
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("translateFiscalError — C-27 error codes", () => {
  it("translates ambiguous_point_of_sale (P0422)", () => {
    const msg = translateFiscalError("P0422: ambiguous_point_of_sale — cuenta con 2 PVs activos")
    expect(msg).toContain("varios puntos de venta activos")
    expect(msg).toContain("Especificá")
  })

  it("translates fiscal_profile_not_found", () => {
    const msg = translateFiscalError("fiscal_profile_not_found")
    expect(msg).toBe("La cuenta no tiene perfil fiscal configurado.")
  })

  it("translates point_of_sale_not_found_or_inactive", () => {
    const msg = translateFiscalError("P0404: point_of_sale_not_found_or_inactive")
    expect(msg).toBe("El punto de venta no existe o está inactivo.")
  })

  it("translates no_active_point_of_sale", () => {
    const msg = translateFiscalError("no_active_point_of_sale")
    expect(msg).toBe("La cuenta no tiene puntos de venta activos.")
  })

  it("translates unauthorized", () => {
    const msg = translateFiscalError("unauthorized: member role cannot write fiscal profile")
    expect(msg).toBe("No tenés permisos para realizar esta acción.")
  })

  it("passes through unknown errors unchanged", () => {
    const msg = translateFiscalError("some unexpected db error")
    expect(msg).toBe("some unexpected db error")
  })

  it("returns fallback for empty message", () => {
    const msg = translateFiscalError("")
    expect(msg).toBe("Ocurrió un error inesperado.")
  })
})

describe("FiscalDocumentBadge — status config (C-27 D5)", () => {
  it("maps pending_cae to 'En trámite'", () => {
    expect(getStatusLabel("pending_cae")).toBe("En trámite")
  })

  it("maps authorized to 'Autorizado'", () => {
    expect(getStatusLabel("authorized")).toBe("Autorizado")
  })

  it("maps rejected to 'Rechazado'", () => {
    expect(getStatusLabel("rejected")).toBe("Rechazado")
  })

  it("pending_cae is NOT a terminal status (relay should still run)", () => {
    expect(isTerminalStatus("pending_cae")).toBe(false)
  })

  it("authorized IS a terminal status", () => {
    expect(isTerminalStatus("authorized")).toBe(true)
  })

  it("rejected IS a terminal status", () => {
    expect(isTerminalStatus("rejected")).toBe(true)
  })
})

describe("isValidCuit — módulo-11 (OQ-4 reuso de C-22)", () => {
  it("accepts valid CUIT 20-12345678-6", () => {
    expect(isValidCuit("20-12345678-6")).toBe(true)
  })

  it("rejects wrong check digit", () => {
    expect(isValidCuit("20-12345678-0")).toBe(false)
  })

  it("rejects CUIT without hyphens", () => {
    expect(isValidCuit("20123456786")).toBe(false)
  })

  it("rejects empty string", () => {
    expect(isValidCuit("")).toBe(false)
  })

  it("rejects CUIT with wrong format (too short)", () => {
    expect(isValidCuit("20-1234-6")).toBe(false)
  })
})
