/**
 * balanza-etiquetas-pos (task 10.3 RED→GREEN) — búsqueda EXACTA por código
 * de balanza en `ProductPicker` (D2, compartido por POS, formulario de venta
 * y formulario de compra): "509" encuentra el producto con PLU 509; "5" y
 * "50" no lo encuentran por PLU (aunque sí podrían por nombre/SKU/barcode si
 * coincidieran con esos, que no es el caso acá).
 */

import React from "react"
import { describe, it, expect } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import { ProductPicker } from "@/components/shared/product-picker"
import type { Product } from "@/lib/types"

const TOMATE: Product = {
  id: "p-tomate", name: "Tomate", category: "Verdulería",
  cost: 2, price: 4.8, margin: 40, stock: 10, minStock: 0,
  isVariant: false, stockControlType: "tracked", scalePlu: 509,
}
const PAPA: Product = {
  id: "p-papa", name: "Papa", category: "Verdulería",
  cost: 5, price: 10, margin: 50, stock: 3, minStock: 0,
  isVariant: false, stockControlType: "tracked", scalePlu: 5091,
}
const PRODUCTS = [TOMATE, PAPA]
const productById = new Map(PRODUCTS.map((p) => [p.id, p]))

function renderPicker() {
  render(
    <ProductPicker
      products={PRODUCTS}
      productById={productById}
      unitsById={new Map()}
      value=""
      onValueChange={() => {}}
    />,
  )
  fireEvent.click(screen.getByRole("combobox"))
}

describe("ProductPicker — búsqueda exacta por Código de balanza (D2)", () => {
  it('"509" encuentra el producto con ese PLU exacto', () => {
    renderPicker()
    fireEvent.change(screen.getByPlaceholderText(/buscar producto/i), { target: { value: "509" } })
    expect(screen.getByText("Tomate")).toBeInTheDocument()
    expect(screen.queryByText("Papa")).not.toBeInTheDocument()
  })

  it('"50" no encuentra nada por PLU (subcadena de 509 y de 5091)', () => {
    renderPicker()
    fireEvent.change(screen.getByPlaceholderText(/buscar producto/i), { target: { value: "50" } })
    expect(screen.queryByText("Tomate")).not.toBeInTheDocument()
    expect(screen.queryByText("Papa")).not.toBeInTheDocument()
  })

  it('"5" tampoco encuentra nada por PLU', () => {
    renderPicker()
    fireEvent.change(screen.getByPlaceholderText(/buscar producto/i), { target: { value: "5" } })
    expect(screen.queryByText("Tomate")).not.toBeInTheDocument()
    expect(screen.queryByText("Papa")).not.toBeInTheDocument()
  })

  it("la búsqueda por nombre sigue funcionando", () => {
    renderPicker()
    fireEvent.change(screen.getByPlaceholderText(/buscar producto/i), { target: { value: "tomate" } })
    expect(screen.getByText("Tomate")).toBeInTheDocument()
    expect(screen.queryByText("Papa")).not.toBeInTheDocument()
  })
})
