/**
 * productos-categorias-sku — ProductForm (tasks 11.2 RED, 11.5 TRIANGULATE).
 *
 *  - el selector de categoría es ProductCategorySelect (consume el catálogo;
 *    PRODUCT_CATEGORIES ya no existe);
 *  - la variante NO pide categoría y hereda la del padre (el servidor la
 *    resuelve; el cliente no manda category_id);
 *  - el campo SKU es opcional, se recorta y se envía; vaciarlo lo borra
 *    (tri-estado: la clave viaja en `undefined`/null, nunca ausente);
 *  - el 409 de SKU se muestra sin perder lo cargado.
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

const PARENT: Product = {
  id: "parent-1", name: "Zapatillas", category: "Ropa", categoryId: "cat-ropa",
  cost: 0, price: 0, margin: 0, stock: 0, minStock: 0, isVariant: false, stockControlType: "variant_only",
}

vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [PARENT], addProduct: addProductMock, updateProduct: updateProductMock }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [] }) }))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", () => ({ generateEAN13: () => "7790000000000" }))
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select
      data-testid="category-select"
      aria-label="Categoría"
      value={value ?? ""}
      onChange={(e) => onChange(e.target.value || null)}
    >
      <option value="">Seleccionar categoría</option>
      <option value="cat-ropa">Ropa</option>
      <option value="cat-hogar">Hogar</option>
    </select>
  ),
}))

const { ProductForm } = await import("@/components/forms/product-form")

describe("ProductForm — categoría del catálogo + SKU", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    addProductMock.mockResolvedValue(undefined)
    updateProductMock.mockResolvedValue(undefined)
  })

  it("el selector de categoría es ProductCategorySelect (catálogo de la cuenta)", () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    expect(screen.getByTestId("category-select")).toBeInTheDocument()
    expect(screen.getByLabelText(/^sku/i)).toBeInTheDocument()
  })

  it("alta base envía categoryId y el SKU recortado", async () => {
    const onSuccess = vi.fn()
    render(<ProductForm onSuccess={onSuccess} />)

    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Remera" } })
    fireEvent.change(screen.getByTestId("category-select"), { target: { value: "cat-ropa" } })
    fireEvent.change(screen.getByLabelText(/^sku/i), { target: { value: "  rem-001 " } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))

    await waitFor(() => expect(addProductMock).toHaveBeenCalledTimes(1))
    expect(addProductMock.mock.calls[0][0]).toEqual(
      expect.objectContaining({ name: "Remera", categoryId: "cat-ropa", sku: "rem-001", parentId: undefined }),
    )
    expect(onSuccess).toHaveBeenCalled()
  })

  it("sin categoría en un producto base no envía y avisa", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Remera" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))

    await waitFor(() => expect(toastError).toHaveBeenCalledWith(expect.stringMatching(/categoría/i)))
    expect(addProductMock).not.toHaveBeenCalled()
  })

  it("variante: no pide categoría y no manda categoryId (hereda del padre en el servidor)", async () => {
    render(<ProductForm onSuccess={vi.fn()} defaultParentId="parent-1" />)

    expect(screen.queryByTestId("category-select")).not.toBeInTheDocument()
    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Zapatillas 41" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))

    await waitFor(() => expect(addProductMock).toHaveBeenCalledTimes(1))
    const sent = addProductMock.mock.calls[0][0]
    expect(sent.parentId).toBe("parent-1")
    expect(sent.categoryId).toBeUndefined()
    expect(sent.category).toBe("Ropa")
  })

  it("alta sin SKU envía sku undefined (NULL en la base, nunca cadena vacía)", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Remera" } })
    fireEvent.change(screen.getByTestId("category-select"), { target: { value: "cat-ropa" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))

    await waitFor(() => expect(addProductMock).toHaveBeenCalledTimes(1))
    expect(addProductMock.mock.calls[0][0]).toHaveProperty("sku", undefined)
  })

  it("edición que no toca el SKU lo conserva; vaciarlo lo borra", async () => {
    const initial: Product = {
      id: "p-1", name: "Remera", category: "Ropa", categoryId: "cat-ropa", sku: "REM-001",
      cost: 10, price: 20, margin: 50, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
    }
    const { unmount } = render(<ProductForm onSuccess={vi.fn()} initialData={initial} />)

    expect((screen.getByLabelText(/^sku/i) as HTMLInputElement).value).toBe("REM-001")
    expect((screen.getByTestId("category-select") as HTMLSelectElement).value).toBe("cat-ropa")
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    expect(updateProductMock.mock.calls[0][0]).toEqual(expect.objectContaining({ id: "p-1", sku: "REM-001", categoryId: "cat-ropa" }))
    unmount()

    render(<ProductForm onSuccess={vi.fn()} initialData={initial} />)
    fireEvent.change(screen.getByLabelText(/^sku/i), { target: { value: "   " } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(2))
    expect(updateProductMock.mock.calls[1][0]).toHaveProperty("sku", undefined)
  })

  it("el 409 de SKU se muestra con su mensaje y conserva lo cargado", async () => {
    const onSuccess = vi.fn()
    addProductMock.mockRejectedValueOnce(new Error('El SKU "REM-001" ya pertenece a otro producto de tu cuenta'))
    render(<ProductForm onSuccess={onSuccess} />)

    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Remera" } })
    fireEvent.change(screen.getByTestId("category-select"), { target: { value: "cat-ropa" } })
    fireEvent.change(screen.getByLabelText(/^sku/i), { target: { value: "REM-001" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))

    await waitFor(() => expect(toastError).toHaveBeenCalledWith(expect.stringMatching(/REM-001/)))
    expect(onSuccess).not.toHaveBeenCalled()
    expect((screen.getByPlaceholderText(/remera afa/i) as HTMLInputElement).value).toBe("Remera")
    expect((screen.getByLabelText(/^sku/i) as HTMLInputElement).value).toBe("REM-001")
  })
})
