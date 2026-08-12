/**
 * TDD tests for the canonical revenue helpers (kpi-ia-canonical-revenue, grupo 1).
 *
 * `lineRevenue`/`sumLineRevenue` son la única fórmula de revenue de línea del
 * frontend — ver openspec/specs/reporting-invariants/spec.md. El caso testigo
 * (1.2) es la venta multi-unidad que hoy subcuenta en los 4 consumidores de IA
 * rotos: `amount` es precio unitario, `total` es el subtotal de línea.
 */

import { describe, it, expect } from "vitest"
import {
  lineRevenue,
  sumLineRevenue,
  netMarginPct,
  previousWindow,
  type SaleRevenueRow,
} from "@/lib/reporting/revenue-canon"

describe("lineRevenue", () => {
  it("caso testigo: venta multi-unidad aporta el total de línea, no el precio unitario (1.2)", () => {
    const row: SaleRevenueRow = { amount: 1000, quantity: 3, total: 3000 }
    expect(lineRevenue(row)).toBe(3000)
  })

  it("fila legacy sin total usa amount (1.4)", () => {
    expect(lineRevenue({ amount: 500, total: null })).toBe(500)
  })

  it("total = 0 legítimo aporta 0 y NO cae al fallback de amount (bug clásico || vs ??) (1.4)", () => {
    expect(lineRevenue({ amount: 900, total: 0 })).toBe(0)
  })

  it("numerics como string no pierden decimales (1.4)", () => {
    expect(lineRevenue({ amount: "1000", total: "1500.50" })).toBe(1500.5)
  })

  it("amount y total ambos NULL aportan 0 (1.4)", () => {
    expect(lineRevenue({ amount: null, total: null })).toBe(0)
  })
})

describe("sumLineRevenue", () => {
  it("suma el revenue de línea de varias filas", () => {
    const rows: SaleRevenueRow[] = [
      { amount: 1000, total: 3000 },
      { amount: 500, total: null },
    ]
    expect(sumLineRevenue(rows)).toBe(3500)
  })

  it("lista vacía → 0 (1.4)", () => {
    expect(sumLineRevenue([])).toBe(0)
  })
})

describe("netMarginPct", () => {
  it("devuelve el porcentaje redondeado (1.5)", () => {
    expect(netMarginPct(4000, 9000)).toBe(44)
  })

  it("revenue 0 → null, no 0 (\"sin base de cálculo\" no es \"margen cero\") (1.5)", () => {
    expect(netMarginPct(4000, 0)).toBeNull()
  })

  it("revenue negativo → null (1.5)", () => {
    expect(netMarginPct(4000, -100)).toBeNull()
  })

  it("revenue null → null (1.5)", () => {
    expect(netMarginPct(4000, null)).toBeNull()
  })

  it("ganancia negativa se informa como margen negativo (1.5)", () => {
    expect(netMarginPct(-1000, 5000)).toBe(-20)
  })
})

describe("previousWindow", () => {
  it("ventana de mes completo: termina justo antes del inicio de la ventana consultada (1.6)", () => {
    const result = previousWindow(
      "2026-07-01T00:00:00.000Z",
      "2026-07-31T23:59:59.999Z",
    )
    expect(result.to).toBe("2026-06-30T23:59:59.999Z")
    expect(result.from).toBe("2026-05-31T00:00:00.000Z")
  })

  it("ventana de 30 días", () => {
    const result = previousWindow(
      "2026-07-12T00:00:00.000Z",
      "2026-08-11T00:00:00.000Z",
    )
    expect(result.to).toBe("2026-07-11T23:59:59.999Z")
    expect(result.from).toBe("2026-06-11T23:59:59.999Z")
  })

  it("ventana de 1 día", () => {
    const result = previousWindow(
      "2026-08-11T00:00:00.000Z",
      "2026-08-11T23:59:59.999Z",
    )
    expect(result.from).toBe("2026-08-10T00:00:00.000Z")
    expect(result.to).toBe("2026-08-10T23:59:59.999Z")
  })

  it("el rango devuelto nunca queda invertido y no se solapa con la ventana original (1.6)", () => {
    const from = "2026-07-01T00:00:00.000Z"
    const to = "2026-07-31T23:59:59.999Z"
    const result = previousWindow(from, to)
    expect(Date.parse(result.from)).toBeLessThanOrEqual(Date.parse(result.to))
    expect(Date.parse(result.to)).toBeLessThan(Date.parse(from))
  })
})
