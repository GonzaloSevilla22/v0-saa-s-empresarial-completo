/**
 * productos-costo-nullable (task 7.7 RED/GREEN) — AiAlerts: un producto sin
 * costo cargado NO genera alerta de margen (no hay margen que evaluar) — en
 * vez de generar una con `(price - 0) / price = 100%` como si fuera un
 * "margen muy alto".
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
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

describe("AiAlerts — margen sin costo", () => {
  it("un producto sin costo cargado no genera ninguna alerta de margen", () => {
    productsMock = [product({ id: "sin-costo", name: "Sin Costo", cost: null, price: 100 })]
    const { container } = render(<AiAlerts />)
    // Sin ninguna otra alerta disparable, el componente no renderiza nada.
    expect(container.firstChild).toBeNull()
  })

  it("un producto con costo real que produce margen alto sigue generando su alerta", () => {
    productsMock = [product({ id: "margen-alto", name: "Margen Alto", cost: 10, price: 100 })]
    render(<AiAlerts />)
    expect(screen.getByText(/margen alto/i)).toBeInTheDocument()
  })
})
