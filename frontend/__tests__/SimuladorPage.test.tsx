/**
 * productos-costo-nullable (task 7.8 RED/GREEN) — /simulador: sin costo
 * cargado, avisa "este producto no tiene costo cargado" y deshabilita la
 * simulación de margen (nunca inventa un margen desde un costo imputado a 0).
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

let productsMock: Product[] = []
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: productsMock }) }))
vi.mock("@/hooks/data/use-sales", () => ({ useSales: () => ({ sales: [] }) }))
vi.mock("@/lib/supabase/client", () => ({ createClient: () => ({ auth: { getSession: async () => ({ data: { session: null } }) } }) }))

const { default: SimuladorPage } = await import("@/app/(dashboard)/simulador/page")

function product(overrides: Partial<Product>): Product {
  return {
    id: "p-1", name: "Producto", category: "General", categoryId: null,
    cost: 50, price: 100, margin: 50, stock: 5, minStock: 1,
    isVariant: false, stockControlType: "tracked",
    ...overrides,
  }
}

describe("/simulador — costo opcional", () => {
  it("un producto sin costo cargado avisa y no muestra un margen inventado", () => {
    productsMock = [product({ id: "sin-costo", name: "Sin Costo", cost: null })]
    render(<SimuladorPage />)
    expect(screen.getByText(/este producto no tiene costo cargado/i)).toBeInTheDocument()
    // Ningún margen (ni "0%" ni el 100% que ((price-0)/price) produciría).
    expect(screen.queryByText("100%")).not.toBeInTheDocument()
  })

  it("un producto con costo real muestra el margen normalmente", () => {
    productsMock = [product({ id: "con-costo", name: "Con Costo", cost: 50, price: 100 })]
    render(<SimuladorPage />)
    expect(screen.queryByText(/este producto no tiene costo cargado/i)).not.toBeInTheDocument()
    expect(screen.getAllByText("50%").length).toBeGreaterThan(0)
  })
})
