/**
 * balanza-etiquetas-pos (task 10.1 RED→GREEN) — campo "Código de balanza
 * (PLU)" en `ProductForm`:
 *  - numérico, opcional; oculto para un producto padre (`variant_only`);
 *  - alta: la clave siempre viaja (mismo molde que `cost`/`baseUnitId`);
 *  - edición sin tocar el campo: la clave NO viaja (tri-estado, conserva);
 *  - edición que vacía el campo: viaja `scalePlu: null` (desasigna);
 *  - 409 (`scale_plu_taken`) y 422 (`scale_plu_parent`) del backend se
 *    muestran junto al campo (`error.field === "scale_plu"`);
 *  - un código de barras que decodifica como etiqueta de balanza válida
 *    muestra un aviso no bloqueante sugiriendo el campo PLU.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"
import { PythonApiError } from "@/lib/api/python-api-error"
import { FACTORY_SCALE_SETTINGS } from "@/lib/scale-layout"

const addProductMock = vi.fn()
const updateProductMock = vi.fn()
const toastError = vi.fn()
const toastSuccess = vi.fn()

const EXISTING: Product = {
  id: "prod-1", name: "Tomate", category: "Verdulería", categoryId: "cat-verd",
  cost: 2, price: 4.8, margin: 40, stock: 10, minStock: 5, isVariant: false,
  stockControlType: "tracked", scalePlu: 261,
}

const PARENT: Product = {
  ...EXISTING, id: "prod-parent", name: "Zapatillas", stockControlType: "variant_only", scalePlu: null,
}

let scaleSettingsFixture = { ...FACTORY_SCALE_SETTINGS, enabled: true }

vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [], addProduct: addProductMock, updateProduct: updateProductMock }),
}))
const KG_UNIT = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight" as const, factor: 1, isSystem: true }
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [KG_UNIT] }) }))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/barcode-utils")>()
  return { ...actual, generateEAN13: () => "7790000000000" }
})
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: scaleSettingsFixture, isLoading: false, isError: false, error: null }),
}))
vi.mock("sonner", () => ({ toast: { success: (...a: unknown[]) => toastSuccess(...a), error: (...a: unknown[]) => toastError(...a) } }))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Categoría" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="cat-verd">Verdulería</option>
    </select>
  ),
}))

const { ProductForm } = await import("@/components/forms/product-form")

describe("ProductForm — código de balanza (PLU)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    addProductMock.mockResolvedValue(undefined)
    updateProductMock.mockResolvedValue(undefined)
    scaleSettingsFixture = { ...FACTORY_SCALE_SETTINGS, enabled: true }
  })

  it("muestra el campo Código de balanza para un producto estándar", () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    expect(screen.getByLabelText(/código de balanza/i)).toBeInTheDocument()
  })

  it("oculta el campo para un producto padre (variant_only)", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)
    expect(screen.queryByLabelText(/código de balanza/i)).not.toBeInTheDocument()
  })

  it("precarga el PLU existente en la edición", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    const input = screen.getByLabelText(/código de balanza/i) as HTMLInputElement
    expect(input.value).toBe("261")
  })

  it("alta con PLU: el payload manda scalePlu", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Producto nuevo" } })
    fireEvent.change(screen.getByLabelText(/categoría/i), { target: { value: "cat-verd" } })
    fireEvent.change(screen.getByLabelText(/código de balanza/i), { target: { value: "509" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    const body = addProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.scalePlu).toBe(509)
  })

  it("alta sin tocar el PLU: el payload manda scalePlu null", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Producto nuevo" } })
    fireEvent.change(screen.getByLabelText(/categoría/i), { target: { value: "cat-verd" } })
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalled())
    const body = addProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.scalePlu).toBeNull()
  })

  it("edición sin tocar el PLU: la clave scalePlu NO viaja (conserva)", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect("scalePlu" in body).toBe(false)
  })

  it("edición que vacía el PLU: viaja scalePlu null (desasigna)", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    fireEvent.change(screen.getByLabelText(/código de balanza/i), { target: { value: "" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.scalePlu).toBeNull()
  })

  it("edición que cambia el PLU: viaja el nuevo valor", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    fireEvent.change(screen.getByLabelText(/código de balanza/i), { target: { value: "777" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.scalePlu).toBe(777)
  })

  // Fix F8 (revisión adversarial PR #599): un padre `variant_only` con un
  // `scale_plu` heredado (dato viejo/inconsistente) oculta el campo — sin
  // este fix, la clave queda sin enviar (tri-estado por ausencia) y el
  // backend re-lee el `scale_plu` EXISTENTE de la fila para validar el
  // `stock_control_type` que SÍ viaja siempre: 422 `scale_plu_parent` en
  // CUALQUIER edición (ni siquiera cambiar el nombre), con el campo para
  // corregirlo invisible — sin salida desde la UI.
  it("un padre variant_only con scalePlu heredado se limpia solo al guardar (F8)", async () => {
    const staleParent = { ...PARENT, scalePlu: 509 }
    render(<ProductForm onSuccess={vi.fn()} initialData={staleParent} />)
    expect(screen.queryByLabelText(/código de balanza/i)).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalled())
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.scalePlu).toBeNull()
  })

  it("muestra el 409 del backend (scale_plu_taken) junto al campo", async () => {
    updateProductMock.mockRejectedValueOnce(
      new PythonApiError("El código de balanza 261 ya lo usa otro producto de tu cuenta.", 409, {
        code: "scale_plu_taken", field: "scale_plu",
      }),
    )
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() =>
      expect(screen.getByText(/el código de balanza 261 ya lo usa otro producto/i)).toBeInTheDocument(),
    )
  })

  it("muestra el 422 del backend (scale_plu_parent) junto al campo", async () => {
    updateProductMock.mockRejectedValueOnce(
      new PythonApiError("El código de balanza se asigna a cada variante, no al producto padre.", 422, {
        code: "scale_plu_parent", field: "scale_plu",
      }),
    )
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() =>
      expect(screen.getByText(/se asigna a cada variante, no al producto padre/i)).toBeInTheDocument(),
    )
  })

  it("aviso no bloqueante: un código de barras que decodifica como etiqueta de balanza sugiere el PLU", () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    const barcodeInput = screen.getByPlaceholderText("Código")
    // Tomate, PLU 261, importe 13,63 (D5 del design) — cabecera de fábrica "20".
    fireEvent.change(barcodeInput, { target: { value: "2002610013638" } })
    expect(screen.getByText(/es una etiqueta de balanza/i)).toBeInTheDocument()
  })

  it("sin aviso para un código de barras común", () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    const barcodeInput = screen.getByPlaceholderText("Código")
    fireEvent.change(barcodeInput, { target: { value: "7790001234567" } })
    expect(screen.queryByText(/es una etiqueta de balanza/i)).not.toBeInTheDocument()
  })

  it("aviso no bloqueante: el PLU excede los dígitos del campo Código configurado", () => {
    // Fábrica: campo Código (PLU) del formato de peso tiene 4 dígitos → máximo 9999.
    render(<ProductForm onSuccess={vi.fn()} initialData={{ ...EXISTING, baseUnitId: "u-kg" }} />)
    fireEvent.change(screen.getByLabelText(/código de balanza/i), { target: { value: "12345" } })
    expect(screen.getByText(/tiene más dígitos que el campo código/i)).toBeInTheDocument()
  })

  it("sin aviso cuando el PLU entra en el campo Código configurado", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={{ ...EXISTING, baseUnitId: "u-kg" }} />)
    fireEvent.change(screen.getByLabelText(/código de balanza/i), { target: { value: "509" } })
    expect(screen.queryByText(/tiene más dígitos que el campo código/i)).not.toBeInTheDocument()
  })
})
