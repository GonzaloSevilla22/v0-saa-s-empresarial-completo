/**
 * Corrección del PR #584 (hallazgo menor de la segunda revisión, viene de
 * main): `useState(initialData?.minStock || 10)` convertía el stock mínimo 0
 * ("sin alerta", RN-23) en 10 al editar cualquier otro campo, y
 * `rpc_set_product_min_stock` lo propagaba a todas las sucursales. Con el fix
 * del hook, `minStock` vuelve a ser el número 0 y el `|| 10` pegaba siempre.
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

describe("ProductForm — el stock mínimo 0 sobrevive a una edición", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    updateProductMock.mockResolvedValue(undefined)
  })

  it("editar el precio de un producto con mínimo 0 manda minStock 0 (no 10)", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={{ ...EXISTING_KG, minStock: 0 }} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const payload = updateProductMock.mock.calls[0][0] as Product
    expect(payload.minStock).toBe(0)
  })

  it("triangulación: un alta nueva sin tocar el mínimo sigue arrancando en 10", async () => {
    addProductMock.mockResolvedValue(undefined)
    render(<ProductForm onSuccess={vi.fn()} />)
    await fillNewProductWithKg()
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    expect((addProductMock.mock.calls[0][0] as Product).minStock).toBe(10)
  })
})
