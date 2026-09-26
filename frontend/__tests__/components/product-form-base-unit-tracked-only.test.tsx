/**
 * Corrección del PR #584 (hallazgo bajo, `product-form.tsx:144`): el
 * comentario decía "para un producto no rastreado el selector no se muestra,
 * así que se manda `undefined`", pero el código mandaba la unidad elegida
 * aunque el producto fuera Servicio / Digital. Caso real: se elige "Kilogramo"
 * con Inventario físico, se cambia a Servicio / Digital (el selector
 * desaparece) y se crea el producto → se guardaba una unidad base que el
 * usuario ya no ve, en un producto que no lleva stock.
 *
 * Regla restaurada (la de main, ahora sobre el hook tri-estado): la unidad
 * base sólo viaja para un producto con inventario físico ("tracked").
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product, UnitOfMeasure } from "@/lib/types"

const addProductMock = vi.fn()
const updateProductMock = vi.fn()

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }

vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [], addProduct: addProductMock, updateProduct: updateProductMock }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [KG] }) }))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", () => ({ generateEAN13: () => "7790000000000" }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Categoría" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">—</option>
      <option value="cat-food">Alimentos</option>
    </select>
  ),
}))

const { ProductForm } = await import("@/components/forms/product-form")

const EXISTING_KG: Product = {
  id: "p1", name: "Tomate", category: "Alimentos", categoryId: "cat-food", cost: 500, price: 1000,
  margin: 50, stock: 1, minStock: 0.5, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}

function comboboxShowing(text: RegExp): HTMLElement {
  const match = screen.getAllByRole("combobox").find((el) => text.test(el.textContent ?? ""))
  if (!match) throw new Error(`no combobox muestra ${text}`)
  return match
}

async function fillNewProductWithKg() {
  const user = userEvent.setup()
  fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Tomate" } })
  fireEvent.change(screen.getByLabelText(/categoría/i), { target: { value: "cat-food" } })
  await user.click(comboboxShowing(/seleccionar unidad/i))
  await user.click(await screen.findByRole("option", { name: /kilogramo/i }))
  return user
}

describe("ProductForm — la unidad base sólo viaja con inventario físico", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    addProductMock.mockResolvedValue(undefined)
    updateProductMock.mockResolvedValue(undefined)
  })

  it("alta con Inventario físico + Kilogramo → viaja baseUnitId", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    await fillNewProductWithKg()
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    expect((addProductMock.mock.calls[0][0] as Product).baseUnitId).toBe("u-kg")
  })

  it("alta: elegir Kilogramo y pasar a Servicio / Digital → NO viaja la unidad", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    const user = await fillNewProductWithKg()
    await user.click(comboboxShowing(/inventario físico/i))
    await user.click(await screen.findByRole("option", { name: /servicio \/ digital/i }))
    expect(screen.queryByText(/seleccionar unidad|kilogramo/i)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    const body = addProductMock.mock.calls[0][0] as Product
    expect(body.stockControlType).toBe("untracked")
    expect(body.baseUnitId).toBeUndefined()
  })

  it("edición de un producto rastreado en kg sin tocar nada → conserva kg", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={{ ...EXISTING_KG, minStock: 2 }} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    expect((updateProductMock.mock.calls[0][0] as Product).baseUnitId).toBe("u-kg")
  })
})

/**
 * Hallazgo de esta corrección (no estaba en la revisión): los campos de stock
 * son `<input type="number">` sin `step`, o sea step = 1. Con el stock mínimo
 * decimal que habilita el PR (0,5 kg, decisión 4), el navegador bloquea el
 * submit por `stepMismatch` ("los valores válidos más cercanos son 0 y 1") y
 * el producto no se puede guardar — ni un alta con 0,5 ni la edición de un
 * producto que ya tiene 0,5 en la base.
 */
describe("ProductForm — stock y stock mínimo decimales se pueden guardar", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    addProductMock.mockResolvedValue(undefined)
    updateProductMock.mockResolvedValue(undefined)
  })

  it("edición de un producto en kg con stock mínimo 0,5 → se guarda con 0.5", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING_KG} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    expect((updateProductMock.mock.calls[0][0] as Product).minStock).toBe(0.5)
  })

  it("alta con stock inicial 0,55 y mínimo 0,25 → se guarda con esos valores", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    await fillNewProductWithKg()
    const [stockInput, minInput] = screen.getAllByRole("spinbutton").slice(-2)
    fireEvent.change(stockInput, { target: { value: "0.55" } })
    fireEvent.change(minInput, { target: { value: "0.25" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    const body = addProductMock.mock.calls[0][0] as Product
    expect(body.stock).toBe(0.55)
    expect(body.minStock).toBe(0.25)
  })
})
