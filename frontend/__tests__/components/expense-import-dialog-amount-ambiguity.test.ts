import { describe, it, expect, vi } from "vitest"

vi.mock("@/hooks/data/use-expenses-query", () => ({
  useImportExpenses: () => ({ importMutation: { mutateAsync: vi.fn() }, invalidateLedgers: vi.fn() }),
}))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))

import { parseAndValidate } from "@/components/gastos/expense-import-dialog"
import { formatNumber } from "@/lib/format"

const HEADER = ["Descripción", "Categoría", "Monto", "Fecha"]

/**
 * candidatos-importadores (cierre del 1er heredado de `product-import-decimal-stock`,
 * PR #524): el monto de gasto se lee con `parseAmount` default (mismo
 * contrato de siempre — un punto suelto es decimal) pero ahora avisa cuando
 * el texto también admite lectura como miles, igual que precio/costo del
 * importador de productos (mismo helper `amountAmbiguityWarning`).
 *
 * El texto del warning muestra `formatNumber(value, 4)`, no `formatMoney`
 * (revisión adversarial: `formatMoney` redondea a 2 decimales y miente
 * cuando el valor leído tiene más decimales de los que muestra).
 */
describe("parseAndValidate (gastos) — monto ambiguo (punto único, grupo de miles)", () => {
  it('"1.500" → $1,5 (contrato sin cambios) + warning de ambigüedad', () => {
    const [row] = parseAndValidate([HEADER, ["Publicidad", "Marketing", "1.500", "2026-06-01"]])
    expect(row.resolvedAmount).toBe(1.5)
    expect(row.warnings).toEqual([
      `Monto ambiguo: "1.500" — se interpretó como $ ${formatNumber(1.5, 4)}. Usá coma para decimales y ningún separador para miles.`,
    ])
  })

  it('"1,500" (coma, convención es-AR de miles) → $1500 SIN warning', () => {
    const [row] = parseAndValidate([HEADER, ["Publicidad", "Marketing", "1,500", "2026-06-01"]])
    expect(row.resolvedAmount).toBe(1500)
    expect(row.warnings).toEqual([])
  })

  it('"12000" (sin separador) → $12000 sin warning', () => {
    const [row] = parseAndValidate([HEADER, ["Publicidad", "Marketing", "12000", "2026-06-01"]])
    expect(row.resolvedAmount).toBe(12000)
    expect(row.warnings).toEqual([])
  })
})
