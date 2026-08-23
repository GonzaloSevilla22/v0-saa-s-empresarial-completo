/**
 * cuentas-billetera-tipo (task 5.1) — TDD tests para el módulo canónico
 * `frontend/lib/bank-account-kind.ts`: resuelve etiqueta, ícono y variante
 * de badge para 'bank' y 'wallet'. Espejo de
 * `__tests__/lib/product-stock.test.ts` (mismo criterio fail-open).
 */
import { describe, it, expect } from "vitest"
import { Landmark, Wallet } from "lucide-react"
import {
  getAccountKindLabel,
  getAccountKindIcon,
  getAccountKindBadgeVariant,
  getAccountKindFormLabels,
} from "@/lib/bank-account-kind"

describe("getAccountKindLabel", () => {
  it("resuelve 'Banco' para 'bank'", () => {
    expect(getAccountKindLabel("bank")).toBe("Banco")
  })

  it("resuelve 'Billetera virtual' para 'wallet'", () => {
    expect(getAccountKindLabel("wallet")).toBe("Billetera virtual")
  })

  // ── TRIANGULATE: fail-open sobre valores no reconocidos ──────────────────
  it("fail-open: un valor no reconocido se presenta como 'bank'", () => {
    expect(getAccountKindLabel("crypto")).toBe("Banco")
  })

  it("fail-open: null/undefined se presenta como 'bank'", () => {
    expect(getAccountKindLabel(null)).toBe("Banco")
    expect(getAccountKindLabel(undefined)).toBe("Banco")
  })
})

describe("getAccountKindIcon", () => {
  it("resuelve Landmark para 'bank'", () => {
    expect(getAccountKindIcon("bank")).toBe(Landmark)
  })

  it("resuelve Wallet para 'wallet'", () => {
    expect(getAccountKindIcon("wallet")).toBe(Wallet)
  })
})

describe("getAccountKindBadgeVariant", () => {
  it("resuelve una variante de Badge (token semántico) para 'bank'", () => {
    expect(getAccountKindBadgeVariant("bank")).toBe("outline")
  })

  it("resuelve una variante de Badge distinta para 'wallet'", () => {
    expect(getAccountKindBadgeVariant("wallet")).toBe("secondary")
  })

  it("las variantes de 'bank' y 'wallet' son distinguibles entre sí", () => {
    expect(getAccountKindBadgeVariant("bank")).not.toBe(getAccountKindBadgeVariant("wallet"))
  })
})

describe("getAccountKindFormLabels", () => {
  it("banco: título, rótulo de emisor y CBU", () => {
    const labels = getAccountKindFormLabels("bank")
    expect(labels.dialogTitle).toBe("Nueva cuenta bancaria")
    expect(labels.issuerLabel).toContain("Banco")
    expect(labels.cbuLabel).toContain("CBU")
  })

  it("billetera: título, rótulo de emisor y CVU", () => {
    const labels = getAccountKindFormLabels("wallet")
    expect(labels.dialogTitle).toBe("Nueva billetera virtual")
    expect(labels.issuerLabel).toContain("Billetera")
    expect(labels.cbuLabel).toContain("CVU")
  })
})
