/**
 * remitos-venta (D11, tarea 5.9) — el panel de movimientos de /stock rotula los
 * movimientos del remito ("Remito R-…", "Edición de remito R-…", "Anulación de
 * remito R-…") con enlace a `/remitos/<reference_id>`.
 *
 * El panel lee `stock_movements` directo por supabase-js, así que el número se
 * resuelve EN EL PANEL con una segunda consulta por página
 * (`delivery_notes.select("id, number, direction").in("id", refIds)`), sólo para
 * los `reference_id` de movimientos del remito. Si esa consulta falla, la fila
 * dice "Remito" sin número y el panel no se rompe. El mismo rótulo lo usa la
 * exportación CSV (columna "Tipo").
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { StockMovement } from "@/lib/types"

const mocks = vi.hoisted(() => ({
  fromCalls: [] as string[],
  inCalls: [] as Array<{ table: string; column: string; values: unknown[] }>,
  results: {} as Record<string, { data: unknown; error: unknown } | "throw">,
}))

vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [] }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    from: (table: string) => {
      mocks.fromCalls.push(table)
      const builder: Record<string, unknown> = {}
      for (const method of ["select", "order", "range", "eq"]) builder[method] = () => builder
      builder.in = (column: string, values: unknown[]) => {
        mocks.inCalls.push({ table, column, values })
        return builder
      }
      builder.then = (resolve: (value: unknown) => void, reject: (reason: unknown) => void) => {
        const result = mocks.results[table]
        if (result === "throw") return reject(new Error("red caída"))
        return resolve(result ?? { data: [], error: null })
      }
      return builder
    },
  }),
}))

import { MovementRow, StockMovementsPanel } from "@/components/stock/stock-movements-panel"

function row(overrides: Record<string, unknown> = {}) {
  return {
    id: "m-1",
    user_id: "u-1",
    product_id: "p-1",
    product_name: "Remera",
    type: "sale",
    quantity_delta: "-2",
    quantity_before: "10",
    quantity_after: "8",
    reference_id: "dn-1",
    reference_type: "delivery_note",
    created_at: "2026-10-02T15:00:00Z",
    ...overrides,
  }
}

function movement(overrides: Partial<StockMovement> = {}): StockMovement {
  return {
    id: "m-1",
    userId: "u-1",
    productId: "p-1",
    productName: "Remera",
    type: "sale",
    quantityDelta: -2,
    quantityBefore: 10,
    quantityAfter: 8,
    referenceId: "dn-1",
    referenceType: "delivery_note",
    createdAt: "2026-10-02T15:00:00Z",
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  mocks.fromCalls.length = 0
  mocks.inCalls.length = 0
  mocks.results = {}
})

describe("MovementRow — rótulo del remito", () => {
  const refs = new Map([["dn-1", { number: 12, direction: "sale" as const }]])

  it("emisión: 'Remito R-00000012' con enlace al remito", () => {
    render(<MovementRow m={movement()} deliveryNotes={refs} />)
    const link = screen.getByRole("link", { name: /Remito R-00000012/ })
    expect(link).toHaveAttribute("href", "/remitos/dn-1")
    expect(screen.queryByText("Venta")).not.toBeInTheDocument()
  })

  it("edición y anulación se rotulan por su reference_type, con el ícono y el sentido del type intactos", () => {
    const { rerender } = render(
      <MovementRow m={movement({ type: "sale_return", referenceType: "delivery_note_update", quantityDelta: 2 })} deliveryNotes={refs} />,
    )
    expect(screen.getByRole("link", { name: /Edición de remito R-00000012/ })).toBeInTheDocument()
    expect(screen.getByText("+2")).toBeInTheDocument()
    rerender(
      <MovementRow m={movement({ type: "sale_return", referenceType: "delivery_note_reversal", quantityDelta: 2 })} deliveryNotes={refs} />,
    )
    expect(screen.getByRole("link", { name: /Anulación de remito R-00000012/ })).toBeInTheDocument()
  })

  it("sin número resuelto dice 'Remito' y conserva el enlace", () => {
    render(<MovementRow m={movement()} />)
    const link = screen.getByRole("link", { name: "Remito" })
    expect(link).toHaveAttribute("href", "/remitos/dn-1")
  })

  it("una venta común conserva 'Venta' y no tiene enlace", () => {
    render(<MovementRow m={movement({ referenceType: "sale", referenceId: "s-1" })} deliveryNotes={refs} />)
    expect(screen.getByText("Venta")).toBeInTheDocument()
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
  })
})

describe("StockMovementsPanel — número del remito por segunda consulta", () => {
  it("resuelve el número de los remitos de la página con UNA consulta a delivery_notes por sus ids", async () => {
    mocks.results.stock_movements = {
      data: [
        row({ id: "m-1", reference_id: "dn-1", reference_type: "delivery_note" }),
        row({ id: "m-2", reference_id: "dn-1", reference_type: "delivery_note_reversal", type: "sale_return", quantity_delta: "2" }),
        row({ id: "m-3", reference_id: "s-9", reference_type: "sale", product_name: "Otra" }),
      ],
      error: null,
    }
    mocks.results.delivery_notes = { data: [{ id: "dn-1", number: 12, direction: "sale" }], error: null }

    render(<StockMovementsPanel />)
    fireEvent.click(screen.getByRole("button", { name: /historial de movimientos/i }))

    expect(await screen.findByRole("link", { name: "Remito R-00000012" })).toHaveAttribute("href", "/remitos/dn-1")
    expect(screen.getByRole("link", { name: "Anulación de remito R-00000012" })).toBeInTheDocument()
    // La venta común sigue como "Venta".
    expect(screen.getByText("Venta")).toBeInTheDocument()

    const calls = mocks.inCalls.filter((c) => c.table === "delivery_notes")
    expect(calls).toHaveLength(1)
    expect(calls[0].column).toBe("id")
    // Sin repetidos y sin el id de la venta.
    expect(calls[0].values).toEqual(["dn-1"])
  })

  it("si ninguna fila es de un remito no hace la segunda consulta", async () => {
    mocks.results.stock_movements = {
      data: [row({ id: "m-3", reference_id: "s-9", reference_type: "sale" })],
      error: null,
    }
    render(<StockMovementsPanel />)
    fireEvent.click(screen.getByRole("button", { name: /historial de movimientos/i }))
    await screen.findByText("Venta")
    expect(mocks.fromCalls).not.toContain("delivery_notes")
  })

  it("si la segunda consulta devuelve error, la fila dice 'Remito' sin número y el panel sigue andando", async () => {
    mocks.results.stock_movements = { data: [row()], error: null }
    mocks.results.delivery_notes = { data: null, error: { message: "rls" } }
    render(<StockMovementsPanel />)
    fireEvent.click(screen.getByRole("button", { name: /historial de movimientos/i }))
    const link = await screen.findByRole("link", { name: "Remito" })
    expect(link).toHaveAttribute("href", "/remitos/dn-1")
    expect(screen.getByText(/1 movimiento/)).toBeInTheDocument()
  })

  it("si la segunda consulta lanza, tampoco rompe el panel", async () => {
    mocks.results.stock_movements = { data: [row()], error: null }
    mocks.results.delivery_notes = "throw"
    render(<StockMovementsPanel />)
    fireEvent.click(screen.getByRole("button", { name: /historial de movimientos/i }))
    expect(await screen.findByRole("link", { name: "Remito" })).toBeInTheDocument()
  })
})

describe("StockMovementsPanel — exportación CSV con el mismo rótulo", () => {
  async function exportedCsv(): Promise<string> {
    let captured: Blob | null = null
    const create = vi.spyOn(URL, "createObjectURL").mockImplementation((blob) => {
      captured = blob as Blob
      return "blob:test"
    })
    vi.spyOn(URL, "revokeObjectURL").mockImplementation(() => undefined)
    vi.spyOn(HTMLAnchorElement.prototype, "click").mockImplementation(() => undefined)
    fireEvent.click(screen.getByTitle("Exportar CSV"))
    expect(create).toHaveBeenCalled()
    return await new Promise<string>((resolve, reject) => {
      const reader = new FileReader()
      reader.onload = () => resolve(String(reader.result))
      reader.onerror = () => reject(reader.error)
      reader.readAsText(captured as unknown as Blob)
    })
  }

  it("la columna 'Tipo' de una fila del remito dice 'Remito R-…', no 'Venta'", async () => {
    mocks.results.stock_movements = {
      data: [row({ id: "m-1" }), row({ id: "m-3", reference_id: "s-9", reference_type: "sale", product_name: "Otra" })],
      error: null,
    }
    mocks.results.delivery_notes = { data: [{ id: "dn-1", number: 12, direction: "sale" }], error: null }
    render(<StockMovementsPanel />)
    fireEvent.click(screen.getByRole("button", { name: /historial de movimientos/i }))
    await screen.findByRole("link", { name: "Remito R-00000012" })

    const csv = await exportedCsv()
    const lines = csv.split("\n")
    const remitoLine = lines.find((l) => l.includes('"Remera"'))
    const ventaLine = lines.find((l) => l.includes('"Otra"'))
    expect(remitoLine).toContain('"Remito R-00000012"')
    expect(remitoLine).not.toContain('"Venta"')
    expect(ventaLine).toContain('"Venta"')
  })

  it("con la segunda consulta caída, el CSV dice 'Remito' sin número", async () => {
    mocks.results.stock_movements = { data: [row()], error: null }
    mocks.results.delivery_notes = { data: null, error: { message: "rls" } }
    render(<StockMovementsPanel />)
    fireEvent.click(screen.getByRole("button", { name: /historial de movimientos/i }))
    await screen.findByRole("link", { name: "Remito" })
    const csv = await exportedCsv()
    expect(csv).toContain('"Remito"')
    expect(csv).not.toContain("R-")
  })
})
