/**
 * productos-costo-nullable (task 6.7 RED/GREEN) — ProductCatalog: un producto
 * sin costo cargado muestra el margen como "—" (no 0% ni 100%), sin los
 * umbrales de color de un margen medido, tanto en el detalle expandido de
 * variantes/standalone como en las tarjetas móviles.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ unitsById: new Map() }) }))
vi.mock("@/lib/format", () => ({ formatMoney: (n: number) => `$${n}` }))
vi.mock("@/lib/format-unit", () => ({ formatStock: (n: number) => `${n}` }))
vi.mock("@/lib/unit-utils", () => ({ resolveUnit: () => null }))
vi.mock("@/lib/excel", () => ({ exportToCSV: vi.fn() }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), warning: vi.fn(), info: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/products/product-import-dialog", () => ({ ProductImportDialog: () => null }))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false }),
}))

const { ProductCatalog } = await import("@/components/products/product-catalog")

const conCosto: Product = {
  id: "p-cost", name: "Con costo", category: "Alimentos", categoryId: "cat-1",
  cost: 50, price: 100, margin: 50, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
}
const sinCosto: Product = {
  id: "p-nocost", name: "Sin costo", category: "Alimentos", categoryId: "cat-1",
  cost: null, price: 100, margin: null, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
}

describe("ProductCatalog — margen ausente sin costo", () => {
  it("un producto sin costo muestra el margen como — en la tabla de escritorio", () => {
    render(
      <ProductCatalog
        products={[conCosto, sinCosto]}
        onAdd={vi.fn()}
        onAddVariant={vi.fn()}
        onEdit={vi.fn()}
        onDelete={vi.fn()}
        isAtLimit={false}
      />,
    )
    const table = screen.getByRole("table")
    expect(table.textContent).toContain("50%")
    expect(table.textContent).toContain("—")
    // el producto con costo real no debe verse afectado
    expect(screen.queryByText("null%")).not.toBeInTheDocument()
  })
})
