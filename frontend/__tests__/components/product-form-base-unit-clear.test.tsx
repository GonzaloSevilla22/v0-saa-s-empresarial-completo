/**
 * ventas-unidades-conversion — decisión 7 (OK del PO, 2026-09-27): el
 * selector de unidad del formulario de producto ofrece una opción explícita
 * "Sin unidad" para DESASIGNAR la unidad base. Hasta este cambio no había
 * forma de volver atrás desde la UI: el selector sólo listaba unidades, y el
 * hook ya sabía mandar `base_unit_id: null` (tri-estado por ausencia) pero
 * ningún camino del formulario lo producía.
 *
 * Sigue sujeta a D11/D-C: con stock ≠ 0 o historia en otra unidad el backend
 * rechaza con `409 base_unit_locked` (guard del service + trigger
 * `trg_product_base_unit_guard`); el formulario muestra el mensaje accionable
 * del backend y vuelve el selector a la unidad que el producto conserva.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product, UnitOfMeasure } from "@/lib/types"
import { PythonApiError } from "@/lib/api/python-api-error"

const addProductMock = vi.fn()
const updateProductMock = vi.fn()
const { toastErrorMock } = vi.hoisted(() => ({ toastErrorMock: vi.fn() }))

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }

vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [], addProduct: addProductMock, updateProduct: updateProductMock }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [UN, KG] }) }))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", () => ({ generateEAN13: () => "7790000000000" }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: toastErrorMock } }))
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
  margin: 50, stock: 0, minStock: 0, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}

function comboboxShowing(text: RegExp): HTMLElement {
  const match = screen.getAllByRole("combobox").find((el) => text.test(el.textContent ?? ""))
  if (!match) throw new Error(`no combobox muestra ${text}`)
  return match
}

async function chooseNoUnit(from: RegExp) {
  const user = userEvent.setup()
  await user.click(comboboxShowing(from))
  await user.click(await screen.findByRole("option", { name: /sin unidad/i }))
  return user
}

describe("ProductForm — opción \"Sin unidad\" (decisión 7)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    addProductMock.mockResolvedValue(undefined)
    updateProductMock.mockResolvedValue(undefined)
  })

  it("el selector de unidad ofrece \"Sin unidad\" además de las unidades", async () => {
    const user = userEvent.setup()
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING_KG} />)
    await user.click(comboboxShowing(/kilogramo/i))
    const options = await screen.findAllByRole("option")
    expect(options.map((o) => o.textContent)).toEqual(["Sin unidad", "Unidad (u)", "Kilogramo (kg)"])
  })

  it("edición de un producto en kg → \"Sin unidad\" manda baseUnitId: null explícito (desasigna)", async () => {
    const onSuccess = vi.fn()
    render(<ProductForm onSuccess={onSuccess} initialData={EXISTING_KG} />)
    await chooseNoUnit(/kilogramo/i)
    expect(comboboxShowing(/sin unidad/i)).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    const body = updateProductMock.mock.calls[0][0] as Record<string, unknown>
    // null (desasignar) — NO undefined (conservar): el hook omite la clave
    // sólo cuando es undefined, así que null es lo que viaja como
    // `base_unit_id: null` en el PUT.
    expect(body).toHaveProperty("baseUnitId", null)
    expect(body.id).toBe("p1")
    expect(onSuccess).toHaveBeenCalled()
  })

  it("edición: al elegir \"Sin unidad\" avisa la regla D11 antes de guardar; en el alta no", async () => {
    const { unmount } = render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING_KG} />)
    const hint = /sólo se puede quitar si el producto no tiene stock ni movimientos/i
    expect(screen.queryByText(hint)).not.toBeInTheDocument()
    await chooseNoUnit(/kilogramo/i)
    expect(screen.getByText(hint)).toBeInTheDocument()
    unmount()

    render(<ProductForm onSuccess={vi.fn()} />)
    await chooseNoUnit(/seleccionar unidad/i)
    expect(screen.queryByText(hint)).not.toBeInTheDocument()
  })

  it("edición: elegir \"Sin unidad\" y volver a Unidad → viaja la unidad elegida, no null", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING_KG} />)
    const user = await chooseNoUnit(/kilogramo/i)
    await user.click(comboboxShowing(/sin unidad/i))
    await user.click(await screen.findByRole("option", { name: /^unidad/i }))
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    expect((updateProductMock.mock.calls[0][0] as Product).baseUnitId).toBe("u-un")
  })

  it("alta con \"Sin unidad\" → el producto se crea sin unidad base (igual que hoy)", async () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    fireEvent.change(screen.getByPlaceholderText(/remera afa/i), { target: { value: "Bolsa" } })
    fireEvent.change(screen.getByLabelText(/categoría/i), { target: { value: "cat-food" } })
    await chooseNoUnit(/seleccionar unidad/i)
    fireEvent.click(screen.getByRole("button", { name: /crear producto/i }))
    await waitFor(() => expect(addProductMock).toHaveBeenCalledTimes(1))
    const body = addProductMock.mock.calls[0][0] as Record<string, unknown>
    expect(body.baseUnitId ?? null).toBeNull()
    expect(body.stockControlType).toBe("tracked")
  })

  it("edición sin tocar el selector de un producto sin unidad → no manda la clave (conserva)", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={{ ...EXISTING_KG, baseUnitId: undefined }} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    expect((updateProductMock.mock.calls[0][0] as Product).baseUnitId).toBeUndefined()
  })
})

describe("ProductForm — \"Sin unidad\" rechazado por D11 (409 base_unit_locked)", () => {
  const LOCKED_DETAIL =
    "No se puede cambiar la unidad base de este producto: ya tiene stock o movimientos registrados en la unidad actual"

  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("muestra el mensaje accionable del backend y vuelve el selector a la unidad que conserva", async () => {
    updateProductMock.mockRejectedValueOnce(
      new PythonApiError(LOCKED_DETAIL, 409, { code: "base_unit_locked", field: "base_unit_id" }),
    )
    const onSuccess = vi.fn()
    render(<ProductForm onSuccess={onSuccess} initialData={{ ...EXISTING_KG, stock: 12 }} />)
    await chooseNoUnit(/kilogramo/i)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith(LOCKED_DETAIL))
    await waitFor(() => expect(comboboxShowing(/kilogramo/i)).toBeInTheDocument())
    expect(screen.getAllByRole("combobox").some((el) => /sin unidad/i.test(el.textContent ?? ""))).toBe(false)
    expect(onSuccess).not.toHaveBeenCalled()
  })

  it("el 409 del trigger (P0409, detail 'base_unit_locked: …') también vuelve a la unidad que conserva", async () => {
    const triggerDetail =
      "base_unit_locked: el producto p1 ya tiene stock o movimientos en su unidad base actual"
    updateProductMock.mockRejectedValueOnce(new PythonApiError(triggerDetail, 409, { code: "P0409" }))
    render(<ProductForm onSuccess={vi.fn()} initialData={{ ...EXISTING_KG, stock: 12 }} />)
    await chooseNoUnit(/kilogramo/i)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith(triggerDetail))
    await waitFor(() => expect(comboboxShowing(/kilogramo/i)).toBeInTheDocument())
  })

  it("otro 409 (SKU repetido) NO toca la unidad elegida: el formulario conserva lo cargado", async () => {
    const skuDetail = "Ya existe un producto con el SKU REM-001 en esta cuenta"
    updateProductMock.mockRejectedValueOnce(new PythonApiError(skuDetail, 409, { code: "sku_taken", field: "sku" }))
    render(<ProductForm onSuccess={vi.fn()} initialData={EXISTING_KG} />)
    await chooseNoUnit(/kilogramo/i)
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith(skuDetail))
    expect(comboboxShowing(/sin unidad/i)).toBeInTheDocument()
  })
})
