/**
 * CASH_MOVEMENT_META / CASH_MOVEMENT_FAMILIES — caja-compras-cobranzas
 * (task 2.6 RED->GREEN). Extendido por cobranzas-reverso (task 11.5,
 * 2026-09-02) — 11 → 13 tipos.
 *
 * El enum de cash_movements.movement_type pasa de 8 a 11 (caja-compras-
 * cobranzas) y luego de 11 a 13 (cobranzas-reverso: payment_received_
 * reversal/payment_made_reversal, D10). Este test fija el contrato del
 * vocabulario del frontend: entrada por cada uno de los 13, el relabel de
 * purchase_payment (OQ-3) y la familia/signo correctos de los tipos nuevos.
 */
import { describe, it, expect } from "vitest"
import { CASH_MOVEMENT_META, CASH_MOVEMENT_FAMILIES } from "@/lib/ledger/cash-movement-meta"
import type { CashMovementType } from "@/lib/types"

const ALL_THIRTEEN_TYPES: CashMovementType[] = [
  "sale", "purchase_payment", "expense", "advance", "withdrawal",
  "sale_reversal", "expense_reversal",
  "purchase_payment_reversal", "payment_received", "payment_made",
  "payment_received_reversal", "payment_made_reversal",
  "adjustment",
]

describe("CASH_MOVEMENT_META — vocabulario de 13 tipos", () => {
  it("tiene una entrada para cada uno de los 13 tipos", () => {
    for (const t of ALL_THIRTEEN_TYPES) {
      expect(CASH_MOVEMENT_META[t]).toBeDefined()
      expect(CASH_MOVEMENT_META[t].label).toBeTruthy()
    }
    expect(Object.keys(CASH_MOVEMENT_META)).toHaveLength(13)
  })

  it("payment_received_reversal y payment_made_reversal tienen etiquetas propias y distintas entre sí", () => {
    expect(CASH_MOVEMENT_META.payment_received_reversal.label).toBe("Anulación de cobro")
    expect(CASH_MOVEMENT_META.payment_made_reversal.label).toBe("Anulación de pago")
    expect(CASH_MOVEMENT_META.payment_received_reversal.label)
      .not.toBe(CASH_MOVEMENT_META.payment_made_reversal.label)
  })

  it("las dos anulaciones tienen tonos OPUESTOS (D10: signo opuesto entre sí)", () => {
    expect(CASH_MOVEMENT_META.payment_received_reversal.tone).toBe("destructive")
    expect(CASH_MOVEMENT_META.payment_made_reversal.tone).toBe("success")
  })

  it("purchase_payment dice 'Compra en efectivo' (relabel OQ-3) — NO 'Pago a proveedor'", () => {
    expect(CASH_MOVEMENT_META.purchase_payment.label).toBe("Compra en efectivo")
    expect(CASH_MOVEMENT_META.purchase_payment.label).not.toMatch(/proveedor/i)
  })

  it("payment_made dice 'Pago a proveedor' — el nombre que purchase_payment dejó libre", () => {
    expect(CASH_MOVEMENT_META.payment_made.label).toBe("Pago a proveedor")
  })

  it("payment_received dice 'Cobro de cliente'", () => {
    expect(CASH_MOVEMENT_META.payment_received.label).toBe("Cobro de cliente")
  })

  it("purchase_payment_reversal dice 'Reversa de compra'", () => {
    expect(CASH_MOVEMENT_META.purchase_payment_reversal.label).toBe("Reversa de compra")
  })

  it("las dos etiquetas nuevas de pago/cobro son distintas entre sí y de purchase_payment", () => {
    const labels = new Set([
      CASH_MOVEMENT_META.purchase_payment.label,
      CASH_MOVEMENT_META.payment_made.label,
      CASH_MOVEMENT_META.payment_received.label,
    ])
    expect(labels.size).toBe(3)
  })

  it("los tonos de las entradas nuevas son semánticos (success/destructive/warning), nunca literales", () => {
    const SEMANTIC_TONES = new Set(["success", "destructive", "warning", "primary", "muted"])
    for (const t of ["purchase_payment_reversal", "payment_received", "payment_made", "payment_received_reversal", "payment_made_reversal"] as const) {
      expect(SEMANTIC_TONES.has(CASH_MOVEMENT_META[t].tone)).toBe(true)
    }
  })
})

describe("CASH_MOVEMENT_FAMILIES — familia de filtro de los tipos nuevos", () => {
  function familyOf(type: CashMovementType): string | undefined {
    return CASH_MOVEMENT_FAMILIES.find((f) => f.types.includes(type))?.key
  }

  it("purchase_payment_reversal cae en Reversas, junto a sale_reversal y expense_reversal", () => {
    expect(familyOf("purchase_payment_reversal")).toBe("reversal")
    const reversalFamily = CASH_MOVEMENT_FAMILIES.find((f) => f.key === "reversal")!
    expect(reversalFamily.types).toEqual(
      expect.arrayContaining(["sale_reversal", "expense_reversal", "purchase_payment_reversal"])
    )
  })

  it("payment_received cae en Ingresos", () => {
    expect(familyOf("payment_received")).toBe("income")
  })

  it("payment_made cae en Egresos", () => {
    expect(familyOf("payment_made")).toBe("expense")
  })

  it("cada tipo pertenece a EXACTAMENTE una familia (sin la 'all', que agrupa todo)", () => {
    for (const t of ALL_THIRTEEN_TYPES) {
      const matches = CASH_MOVEMENT_FAMILIES.filter((f) => f.key !== "all" && f.types.includes(t))
      expect(matches).toHaveLength(1)
    }
  })

  it("payment_received_reversal y payment_made_reversal caen en Reversas, junto a las otras tres", () => {
    expect(familyOf("payment_received_reversal")).toBe("reversal")
    expect(familyOf("payment_made_reversal")).toBe("reversal")
    const reversalFamily = CASH_MOVEMENT_FAMILIES.find((f) => f.key === "reversal")!
    expect(reversalFamily.types).toEqual(
      expect.arrayContaining([
        "sale_reversal", "expense_reversal", "purchase_payment_reversal",
        "payment_received_reversal", "payment_made_reversal",
      ])
    )
  })
})
