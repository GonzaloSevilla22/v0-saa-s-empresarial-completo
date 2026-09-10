/**
 * productos-costo-nullable (task 6.6 RED/GREEN) — ProductForm admite dejar el
 * costo vacío:
 *  - el input de costo es `nullable` (NumericInput) y muestra el texto de
 *    ayuda "Dejalo vacío si todavía no sabés el costo";
 *  - sin costo, el margen se muestra "—", nunca 0% ni 100%;
 *  - alta sin tocar el costo → el payload manda `cost: null` (D10: para un
 *    alta, ausencia y null explícito son equivalentes — el servidor los trata
 *    igual);
 *  - edición sin tocar el costo → la clave NO viaja (se conserva el que tenía,
 *    D12/tri-estado, mismo molde que sku/category_id);
 *  - edición que vacía un costo existente → viaja `cost: null` (desasigna);
 *  - un costo `0` declarado se ve como `0`, no como vacío.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

const addProductMock = vi.fn()
const updateProductMock = vi.fn()
const toastError = vi.fn()
const toastSuccess = vi.fn()

const EXISTING: Product = {
  id: "prod-1", name: "Medialunas", category: "Alimentos", categoryId: "cat-food",
  cost: 500, price: 1000, margin: 50, stock: 10, minStock: 5, isVariant: false, stockControlType: "tracked",
}

const EXISTING_NO_COST: Product = {
  ...EXISTING, id: "prod-2", name: "Sin costo", cost: null, margin: null,
}

vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [], addProduct: addProductMock, updateProduct: updateProductMock }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [] }) }))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", () => ({ generateEAN13: () => "7790000000000" }))
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Categoría" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="cat-food">Alimentos</option>
    </select>
  ),
}))

const { ProductForm } = await import("@/components/forms/product-form")

describe("ProductForm — costo opcional", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    addProductMock.mockResolvedValue(undefined)
    updateProductMock.mockResolvedValue(undefined)
  })

  it("muestra el texto de ayuda para dejar el costo vacío", () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    expect(screen.getByText(/dejalo vacío si todavía no sabés el costo/i)).toBeInTheDocument()
  })

  it("sin costo cargado, el margen se muestra como ausente (—), no 0% ni 100%", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING_NO_COST} />)
    fireEvent.change(screen.getByLabelText(/^precio/i), { target: { value: "1000" } })
    expect(screen.getByText("—")).toBeInTheDocument()
  })

  it("un costo 0 declarado se muestra como 0, y el margen se calcula (100%)", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={{ ...EXISTING, cost: 0, margin: 100 }} />)
    const costInput = screen.getByLabelText(/^costo/i) as HTMLInputElement
    expect(costInput.value).toBe("0")
    expect(screen.getByText("100%")).toBeInTheDocument()
  })

  it("alta sin tocar el costo: el payload manda cost null", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Producto Nuevo" } })
    fireEvent.change(screen.getByLabelText(/categoría/i), { target: { value: "cat-food" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    const body = addProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.cost).toBeNull()
  })

  it("edición sin tocar el costo: la clave cost NO viaja (conserva)", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    fireEvent.change(screen.getByLabelText(/^precio/i), { target: { value: "1200" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect("cost" in body).toBe(false)
  })

  it("edición que vacía el costo: viaja cost null (desasigna)", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    const costInput = screen.getByLabelText(/^costo/i)
    fireEvent.change(costInput, { target: { value: "" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.cost).toBeNull()
  })

  it("edición que cambia el costo: viaja el nuevo valor", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    const costInput = screen.getByLabelText(/^costo/i)
    fireEvent.change(costInput, { target: { value: "777" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.cost).toBe(777)
  })
})
