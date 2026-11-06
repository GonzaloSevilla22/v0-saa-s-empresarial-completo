/**
 * Humo real del PO (2026-11-06) sobre `stock-movimientos-sucursal-origen`: «no veo la
 * sucursal en los movimientos». El change completó `branch_id` en la base pero el panel
 * nunca la mostró. Desde este fix cada fila muestra la sucursal del movimiento (o «Sin
 * sucursal» cuando el ledger no la registra), y la lectura la pide embebida
 * (`branches(name)`), nunca con una consulta por fila.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import React from "react"

const mocks = vi.hoisted(() => ({
  selects: [] as string[],
  results: {} as Record<string, { data: unknown; error: unknown }>,
}))

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [] }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: (table: string) => {
      const builder: Record<string, unknown> = {}
      builder.select = (cols: string) => {
        if (table === "stock_movements") mocks.selects.push(cols)
        return builder
      }
      for (const method of ["order", "range", "eq", "in"]) builder[method] = () => builder
      builder.then = (resolve: (value: unknown) => void) => resolve(mocks.results[table] ?? { data: [], error: null })
      return builder
    },
  }),
}))

import { StockMovementsPanel } from "@/components/stock/stock-movements-panel"

function row(overrides: Record<string, unknown> = {}) {
  return {
    id: "m-1",
    user_id: "u-1",
    product_id: "p-1",
    product_name: "Remera",
    type: "sale",
    quantity_delta: "-1",
    quantity_before: "1",
    quantity_after: "0",
    reference_id: "s-1",
    reference_type: "sale",
    created_at: "2026-11-03T15:50:00Z",
    ...overrides,
  }
}

beforeEach(() => {
  mocks.selects.length = 0
  mocks.results = {}
})

describe("StockMovementsPanel — sucursal del movimiento", () => {
  it("muestra la sucursal registrada en cada movimiento y la pide embebida en la misma lectura", async () => {
    mocks.results.stock_movements = {
      data: [
        row({ id: "m-1", branch_id: "b-1", branches: { name: "Showroom" } }),
        row({ id: "m-2", product_name: "Buzo", branch_id: null, branches: null }),
      ],
      error: null,
    }
    render(<StockMovementsPanel />)
    fireEvent.click(screen.getByRole("button", { name: /Historial de movimientos/i }))

    expect(await screen.findByText("Showroom")).toBeInTheDocument()
    expect(screen.getByText("Sin sucursal")).toBeInTheDocument()
    expect(mocks.selects.some((cols) => cols.includes("branches(name)"))).toBe(true)
  })
})
