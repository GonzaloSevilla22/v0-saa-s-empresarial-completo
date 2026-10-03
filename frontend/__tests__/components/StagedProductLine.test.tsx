/**
 * remitos-compra (D11, tarea 5.2) — `StagedProductLine` con `priceSource`.
 *
 * El renglón "agregar producto" lo comparten venta, presupuesto y remito. En el
 * remito de COMPRA el precio que se precarga es el COSTO (la mercadería se recibe
 * a lo que cuesta), el "Cat." compara contra el costo, el descuento no existe (la
 * compra no lo tiene) y una línea en 0 avisa que la conversión en compra va a
 * exigir el precio. Con la fuente por defecto (`"price"`) el componente sigue
 * siendo el de siempre: precio de venta, descuento visible, sin aviso.
 *
 * El selector de productos se reemplaza por un doble simple; el resto es real.
 */
import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"

import type { StagedCartLine } from "@/lib/cart-utils"
import type { Product, UnitOfMeasure } from "@/lib/types"

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const U: UnitOfMeasure = { id: "u-u", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }
const UNITS = [KG, U]
const UNITS_BY_ID = new Map(UNITS.map((u) => [u.id, u]))

function product(overrides: Partial<Product> & { id: string; name: string }): Product {
  return {
    category: "Otros",
    categoryId: "c1",
    cost: null,
    price: 0,
    margin: null,
    stock: 10,
    minStock: 0,
    isVariant: false,
    stockControlType: "tracked",
    baseUnitId: "u-u",
    ...overrides,
  }
}

const HUEVO = product({ id: "p-huevo", name: "Huevo", cost: 50, price: 100 })
const SIN_COSTO = product({ id: "p-sin", name: "Sin costo", cost: null, price: 80 })
const COSTO_CERO = product({ id: "p-cero", name: "Costo cero", cost: 0, price: 80 })
const QUESO = product({ id: "p-queso", name: "Queso", cost: 600, price: 1800, baseUnitId: "u-kg" })
const PRODUCTS = [HUEVO, SIN_COSTO, COSTO_CERO, QUESO]

vi.mock("@/components/shared/product-picker", () => ({
  ProductPicker: ({ onValueChange }: { onValueChange: (id: string) => void }) => (
    <div>
      {PRODUCTS.map((p) => (
        <button key={p.id} type="button" onClick={() => onValueChange(p.id)}>{`elegir ${p.name}`}</button>
      ))}
    </div>
  ),
}))

const { StagedProductLine } = await import("@/components/shared/StagedProductLine")

function renderLine(props: { priceSource?: "price" | "cost"; onAdd?: (line: StagedCartLine) => boolean } = {}) {
  const onAdd = props.onAdd ?? vi.fn((line: StagedCartLine) => Boolean(line))
  render(
    <StagedProductLine
      products={PRODUCTS}
      productById={new Map(PRODUCTS.map((p) => [p.id, p]))}
      units={UNITS}
      unitsById={UNITS_BY_ID}
      currency="ARS"
      onAdd={onAdd}
      priceSource={props.priceSource}
    />,
  )
  return onAdd
}

const choose = (name: string) => fireEvent.click(screen.getByRole("button", { name: `elegir ${name}` }))
const priceInput = () => screen.getByLabelText(/precio/i) as HTMLInputElement

describe("StagedProductLine — fuente del precio", () => {
  it("por defecto precarga el precio de venta, muestra el descuento y no avisa 'Sin precio'", () => {
    renderLine()
    choose("Huevo")
    expect(priceInput()).toHaveValue(100)
    expect(screen.getByLabelText(/descuento/i)).toBeInTheDocument()
    expect(screen.queryByText(/sin precio/i)).not.toBeInTheDocument()
  })

  it("con 'price' explícito es idéntico al default", () => {
    renderLine({ priceSource: "price" })
    choose("Queso")
    expect(priceInput()).toHaveValue(1800)
    expect(screen.getByLabelText(/descuento/i)).toBeInTheDocument()
  })

  it("con 'cost' precarga el COSTO, no el precio de venta", () => {
    renderLine({ priceSource: "cost" })
    choose("Huevo")
    expect(priceInput()).toHaveValue(50)
    choose("Queso")
    expect(priceInput()).toHaveValue(600)
  })

  it("con 'cost' el rótulo habla de precio de compra y el descuento no existe", () => {
    renderLine({ priceSource: "cost" })
    choose("Huevo")
    expect(screen.getByLabelText(/precio de compra/i)).toBeInTheDocument()
    expect(screen.queryByLabelText(/descuento/i)).not.toBeInTheDocument()
  })

  it("con 'cost' y costo nulo la línea entra en 0 con el aviso 'Sin precio' (no hereda el precio de venta)", () => {
    const onAdd = renderLine({ priceSource: "cost" })
    choose("Sin costo")
    expect(
      screen.getByText("Sin precio: lo vas a poder cargar antes de convertir el remito en compra"),
    ).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    // El precio de VENTA del producto (80) nunca se cuela: entra en 0.
    expect(onAdd).toHaveBeenCalledWith(expect.objectContaining({ unitPrice: 0 }))
  })

  it("con 'cost' y costo 0 declarado también avisa, y el aviso desaparece al cargar un precio", () => {
    renderLine({ priceSource: "cost" })
    choose("Costo cero")
    expect(screen.getByText(/sin precio/i)).toBeInTheDocument()
    fireEvent.change(priceInput(), { target: { value: "35" } })
    expect(screen.queryByText(/sin precio/i)).not.toBeInTheDocument()
  })

  it("con 'cost' el 'Cat.' compara contra el costo: igual al costo no se muestra, distinto sí", () => {
    renderLine({ priceSource: "cost" })
    choose("Huevo")
    expect(screen.queryByText(/^Cat\./)).not.toBeInTheDocument()
    fireEvent.change(priceInput(), { target: { value: "55" } })
    const hint = screen.getByText(/^Cat\./)
    expect(hint).toHaveTextContent(/50/)
    expect(hint).not.toHaveTextContent(/100/)
  })

  it("con 'price' el 'Cat.' sigue comparando contra el precio de venta", () => {
    renderLine({ priceSource: "price" })
    choose("Huevo")
    fireEvent.change(priceInput(), { target: { value: "90" } })
    expect(screen.getByText(/^Cat\./)).toHaveTextContent(/100/)
  })

  it("con 'cost', al agregar entrega el costo y descuento 0", () => {
    const onAdd = renderLine({ priceSource: "cost" })
    choose("Queso")
    fireEvent.change(screen.getByLabelText(/^Cantidad/), { target: { value: "2" } })
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(onAdd).toHaveBeenCalledTimes(1)
    expect(onAdd).toHaveBeenCalledWith(
      expect.objectContaining({ unitPrice: 600, quantity: 2, discount: 0, unitId: "u-kg" }),
    )
  })

  it("con el default, al agregar entrega el precio de venta", () => {
    const onAdd = renderLine()
    choose("Queso")
    fireEvent.click(screen.getByRole("button", { name: /agregar al carrito/i }))
    expect(onAdd).toHaveBeenCalledWith(expect.objectContaining({ unitPrice: 1800 }))
  })
})
