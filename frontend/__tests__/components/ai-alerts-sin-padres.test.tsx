/**
 * Humo del PO (2026-11-06): «en alerta de rentabilidad salen los productos padres,
 * cosas que no sirven que salgan». Un padre no tiene precio propio (desde
 * productos-padre-variantes el `variant_only` lleva precio 0 y costo nulo; un padre
 * `tracked` con hijos conserva valores legacy que no se venden): el margen se evalúa
 * en cada variante, nunca en el padre. Y sin precio no hay margen que evaluar.
 */
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import React from "react"
import type { Product } from "@/lib/types"

let productsMock: Product[] = []
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: productsMock }) }))
vi.mock("@/hooks/data/use-sales", () => ({ useSales: () => ({ sales: [] }) }))

const { AiAlerts } = await import("@/components/dashboard/ai-alerts")

function product(overrides: Partial<Product>): Product {
  return {
    id: "p-1", name: "Producto", category: "General", categoryId: null,
    cost: 10, price: 100, margin: 90, stock: 5, minStock: 1,
    isVariant: false, stockControlType: "tracked",
    ...overrides,
  }
}

describe("AiAlerts — los padres y los productos sin precio no generan alertas de margen", () => {
  it("un padre variant_only (precio 0, costo nulo) no aparece", () => {
    productsMock = [product({ id: "padre", name: "Musculosa Myra", stockControlType: "variant_only", price: 0, cost: null })]
    const { container } = render(<AiAlerts />)
    expect(container).toBeEmptyDOMElement()
  })

  it("un padre tracked con hijos (valores legacy) no aparece, pero su variante con margen bajo sí", () => {
    productsMock = [
      product({ id: "padre", name: "Pantalón Térmico Runa", stockControlType: "tracked", price: 100, cost: 95 }),
      product({ id: "hija", name: "Pantalón Térmico Runa Talle 4", parentId: "padre", isVariant: true, price: 100, cost: 95 }),
    ]
    render(<AiAlerts />)
    expect(screen.getByText("Margen crítico: Pantalón Térmico Runa Talle 4")).toBeInTheDocument()
    expect(screen.queryByText("Margen crítico: Pantalón Térmico Runa")).not.toBeInTheDocument()
  })

  it("un producto sin precio (precio 0) no genera «margen 0 %»", () => {
    productsMock = [product({ id: "sin-precio", name: "Sin Precio", price: 0, cost: 50 })]
    const { container } = render(<AiAlerts />)
    expect(container).toBeEmptyDOMElement()
  })
})
