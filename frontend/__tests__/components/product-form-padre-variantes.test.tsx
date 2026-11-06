/**
 * productos-padre-variantes (tasks 9.1, 9.3, 9.4) — alta y edición diferenciadas.
 *
 *  - paso "¿Qué querés crear?" (producto simple / producto con variantes),
 *    accesible por teclado;
 *  - el formulario del padre pide SÓLO nombre, categoría y unidad de la familia
 *    y su payload no lleva precio, costo, stock, SKU, código de barras ni PLU;
 *  - tras crear el padre pasa a "Agregar la primera variante" con el padre fijo;
 *  - la variante muestra categoría y unidad del padre en sólo lectura, sin
 *    selector de padre;
 *  - el producto simple no tiene selector de padre;
 *  - la edición elige el formulario por modo (incluido el aviso del padre
 *    `tracked` con hijos);
 *  - la sugerencia de precio (costo × 1,5) nunca pisa un precio escrito;
 *  - los rechazos tipados del backend salen en castellano accionable.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product, UnitOfMeasure } from "@/lib/types"
import { PythonApiError } from "@/lib/api/python-api-error"

const addProductMock = vi.fn()
const updateProductMock = vi.fn()
const toastError = vi.fn()
const toastSuccess = vi.fn()

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }

const PARENT: Product = {
  id: "parent-1", name: "Zapatillas", category: "Ropa", categoryId: "cat-ropa",
  cost: null, price: 0, margin: null, stock: 0, minStock: 0, isVariant: false,
  stockControlType: "variant_only", baseUnitId: "u-kg",
}
const VARIANT: Product = {
  id: "var-1", name: "Zapatillas 41", category: "Ropa", categoryId: "cat-ropa",
  cost: 500, price: 1000, margin: 50, stock: 0, minStock: 1, isVariant: true, parentId: "parent-1",
  stockControlType: "tracked", sku: "ZAP-41",
}
const HAND_MADE_PARENT: Product = {
  id: "hand-1", name: "Remera armada a mano", category: "Ropa", categoryId: "cat-ropa",
  cost: 300, price: 800, margin: 62, stock: 5, minStock: 2, isVariant: false,
  stockControlType: "tracked", barcode: "7790009", baseUnitId: "u-un",
}
const HAND_MADE_CHILD: Product = {
  id: "hand-child", name: "Remera armada a mano M", category: "Ropa", categoryId: "cat-ropa",
  cost: 300, price: 800, margin: 62, stock: 1, minStock: 0, isVariant: true, parentId: "hand-1",
  stockControlType: "tracked",
}

let productsList: Product[] = [PARENT, VARIANT]

vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: "owner", roles: ["owner"], rolesResolved: true, isWriter: true, isLoading: false }),
}))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: productsList, addProduct: addProductMock, updateProduct: updateProductMock }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [UN, KG], unitsById: new Map([[UN.id, UN], [KG.id, KG]]) }),
}))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", () => ({ generateEAN13: () => "7790000000000" }))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: { enabled: false, layouts: [] }, isLoading: false, isError: false, error: null }),
}))
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
      <option value="cat-food">Alimentos</option>
    </select>
  ),
}))

const { ProductForm } = await import("@/components/forms/product-form")
const { ProductKindStep } = await import("@/components/forms/ProductKindStep")

async function chooseUnit(user: ReturnType<typeof userEvent.setup>, optionName: RegExp) {
  const trigger = screen.getAllByRole("combobox").find((el) => /seleccionar unidad/i.test(el.textContent ?? ""))
  if (!trigger) throw new Error("no hay selector de unidad")
  await user.click(trigger)
  await user.click(await screen.findByRole("option", { name: optionName }))
}

describe("ProductKindStep", () => {
  it("ofrece dos opciones en un grupo de radio con nombre accesible, y Continuar espera la elección", async () => {
    const onSelect = vi.fn()
    const user = userEvent.setup()
    render(<ProductKindStep onSelect={onSelect} />)

    const group = screen.getByRole("radiogroup", { name: /qué querés crear/i })
    const radios = within(group).getAllByRole("radio")
    expect(radios.map((r) => r.getAttribute("aria-label") ?? r.id)).toHaveLength(2)
    expect(screen.getByRole("radio", { name: /producto simple/i })).toBeInTheDocument()
    expect(screen.getByRole("radio", { name: /producto con variantes/i })).toBeInTheDocument()

    const next = screen.getByRole("button", { name: /continuar/i })
    expect(next).toBeDisabled()

    await user.click(screen.getByRole("radio", { name: /producto con variantes/i }))
    expect(next).toBeEnabled()
    await user.click(next)
    expect(onSelect).toHaveBeenCalledWith("parent")
  })

  it("se opera con teclado: flecha cambia de opción, espacio la elige y Enter continúa", async () => {
    const onSelect = vi.fn()
    const user = userEvent.setup()
    render(<ProductKindStep onSelect={onSelect} />)

    await user.tab()
    expect(screen.getByRole("radio", { name: /producto simple/i })).toHaveFocus()
    await user.keyboard("{ArrowDown}")
    await waitFor(() => expect(screen.getByRole("radio", { name: /producto con variantes/i })).toHaveFocus())
    await user.keyboard(" ")
    expect(screen.getByRole("radio", { name: /producto con variantes/i })).toBeChecked()
    await user.tab()
    expect(screen.getByRole("button", { name: /continuar/i })).toHaveFocus()
    await user.keyboard("{Enter}")
    expect(onSelect).toHaveBeenCalledWith("parent")
  })

  it("TRIANGULATE: la opción simple continúa con 'simple'", async () => {
    const onSelect = vi.fn()
    const user = userEvent.setup()
    render(<ProductKindStep onSelect={onSelect} />)
    await user.click(screen.getByRole("radio", { name: /producto simple/i }))
    await user.click(screen.getByRole("button", { name: /continuar/i }))
    expect(onSelect).toHaveBeenCalledWith("simple")
  })
})

describe("ProductForm — alta diferenciada", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    productsList = [PARENT, VARIANT]
    addProductMock.mockResolvedValue({ id: "new-parent" })
    updateProductMock.mockResolvedValue(undefined)
  })

  it("un alta sin tipo elegido arranca con el paso '¿Qué querés crear?'", () => {
    render(<ProductForm onSuccess={vi.fn()} />)
    expect(screen.getByRole("radiogroup", { name: /qué querés crear/i })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /crear producto/i })).not.toBeInTheDocument()
  })

  it("producto simple: formulario completo y SIN selector de padre", async () => {
    const user = userEvent.setup()
    render(<ProductForm onSuccess={vi.fn()} />)
    await user.click(screen.getByRole("radio", { name: /producto simple/i }))
    await user.click(screen.getByRole("button", { name: /continuar/i }))

    expect(screen.queryByText(/producto padre/i)).not.toBeInTheDocument()
    expect(screen.getByLabelText(/código de barras/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^sku/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^costo/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^precio/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/código de balanza/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/stock inicial/i)).toBeInTheDocument()
    expect(screen.getByTestId("category-select")).toBeInTheDocument()
  })

  it("producto con variantes: el formulario pide sólo nombre, categoría y unidad", async () => {
    const user = userEvent.setup()
    render(<ProductForm onSuccess={vi.fn()} />)
    await user.click(screen.getByRole("radio", { name: /producto con variantes/i }))
    await user.click(screen.getByRole("button", { name: /continuar/i }))

    expect(screen.getByLabelText(/^nombre/i)).toBeInTheDocument()
    expect(screen.getByTestId("category-select")).toBeInTheDocument()
    expect(screen.getByText(/unidad de la familia/i)).toBeInTheDocument()
    for (const absent of [/stock inicial/i, /stock mínimo/i, /código de barras/i, /código de balanza/i, /^sku/i, /^precio/i, /^costo/i]) {
      expect(screen.queryByLabelText(absent)).not.toBeInTheDocument()
    }
  })

  it("crear el padre: payload sin precio/costo/stock/SKU/barcode/PLU y continúa con 'Agregar la primera variante' con el padre fijo", async () => {
    const user = userEvent.setup()
    const onSuccess = vi.fn()
    render(<ProductForm onSuccess={onSuccess} />)
    await user.click(screen.getByRole("radio", { name: /producto con variantes/i }))
    await user.click(screen.getByRole("button", { name: /continuar/i }))

    fireEvent.change(screen.getByLabelText(/^nombre/i), { target: { value: "Remeras" } })
    fireEvent.change(screen.getByTestId("category-select"), { target: { value: "cat-ropa" } })
    await chooseUnit(user, /unidad \(u\)|^unidad/i)
    fireEvent.click(screen.getByRole("button", { name: /crear/i }))

    await waitFor(() => expect(addProductMock).toHaveBeenCalledTimes(1))
    const sent = addProductMock.mock.calls[0][0]
    expect(sent).toMatchObject({
      name: "Remeras",
      categoryId: "cat-ropa",
      stockControlType: "variant_only",
      price: 0,
      stock: 0,
      minStock: 0,
      barcode: "",
      baseUnitId: "u-un",
      isVariant: false,
    })
    expect(sent.parentId).toBeUndefined()
    expect(sent.sku).toBeUndefined()
    expect(sent.cost == null).toBe(true)
    expect(sent.scalePlu == null).toBe(true)

    // El diálogo NO se cierra: pasa a la primera variante con el padre fijo.
    expect(onSuccess).not.toHaveBeenCalled()
    expect(await screen.findByText(/agregar la primera variante/i)).toBeInTheDocument()
    expect(screen.getByText("Remeras")).toBeInTheDocument()
    expect(screen.queryByText(/producto padre \(variante\)/i)).not.toBeInTheDocument()
  })

  it("la primera variante se crea con el padre recién creado y hereda categoría y unidad (no las manda)", async () => {
    const user = userEvent.setup()
    const onSuccess = vi.fn()
    render(<ProductForm onSuccess={onSuccess} />)
    await user.click(screen.getByRole("radio", { name: /producto con variantes/i }))
    await user.click(screen.getByRole("button", { name: /continuar/i }))
    fireEvent.change(screen.getByLabelText(/^nombre/i), { target: { value: "Remeras" } })
    fireEvent.change(screen.getByTestId("category-select"), { target: { value: "cat-ropa" } })
    fireEvent.click(screen.getByRole("button", { name: /crear/i }))
    await screen.findByText(/agregar la primera variante/i)

    addProductMock.mockResolvedValue({ id: "new-variant" })
    fireEvent.change(screen.getByLabelText(/^nombre/i), { target: { value: "Remera M" } })
    fireEvent.click(screen.getByRole("button", { name: /crear variante/i }))

    await waitFor(() => expect(addProductMock).toHaveBeenCalledTimes(2))
    const variant = addProductMock.mock.calls[1][0]
    expect(variant).toMatchObject({ name: "Remera M", parentId: "new-parent", isVariant: true, stockControlType: "tracked" })
    expect(variant.categoryId).toBeUndefined()
    expect(variant.baseUnitId).toBeUndefined()
    await waitFor(() => expect(onSuccess).toHaveBeenCalled())
  })

  it("un error 422 parent_field_not_allowed del servidor sale en castellano accionable", async () => {
    addProductMock.mockRejectedValueOnce(
      new PythonApiError("El campo price no puede informarse en un producto padre", 422, { code: "parent_field_not_allowed", field: "price" }),
    )
    const user = userEvent.setup()
    render(<ProductForm onSuccess={vi.fn()} />)
    await user.click(screen.getByRole("radio", { name: /producto con variantes/i }))
    await user.click(screen.getByRole("button", { name: /continuar/i }))
    fireEvent.change(screen.getByLabelText(/^nombre/i), { target: { value: "Remeras" } })
    fireEvent.change(screen.getByTestId("category-select"), { target: { value: "cat-ropa" } })
    fireEvent.click(screen.getByRole("button", { name: /crear/i }))

    await waitFor(() => expect(toastError).toHaveBeenCalled())
    const shown = String(toastError.mock.calls[0][0])
    expect(shown).toMatch(/cada variante/i)
    expect(shown).not.toContain("parent_field_not_allowed")
    expect(screen.queryByText(/agregar la primera variante/i)).not.toBeInTheDocument()
  })

  it("'Nueva variante' desde la fila: formulario de variante con el padre fijo, categoría y unidad en sólo lectura", () => {
    render(<ProductForm onSuccess={vi.fn()} defaultParentId="parent-1" />)

    expect(screen.queryByRole("radiogroup")).not.toBeInTheDocument()
    expect(screen.queryByText(/producto padre \(variante\)/i)).not.toBeInTheDocument()
    expect(screen.getByText("Zapatillas")).toBeInTheDocument()
    expect(screen.getByTestId("inherited-category")).toHaveTextContent("Ropa")
    expect(screen.getByTestId("inherited-unit")).toHaveTextContent(/kilogramo/i)
    expect(screen.queryByTestId("category-select")).not.toBeInTheDocument()
    // campos propios
    expect(screen.getByLabelText(/código de barras/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^sku/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^precio/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/^costo/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/código de balanza/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/stock inicial/i)).toBeInTheDocument()
  })
})

describe("ProductForm — la edición espeja el modo del producto", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    productsList = [PARENT, VARIANT]
    addProductMock.mockResolvedValue(undefined)
    updateProductMock.mockResolvedValue(undefined)
  })

  it("variant_only → formulario del padre, sin precio, costo, stock, SKU, código de barras ni PLU", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)
    expect(screen.getByLabelText(/^nombre/i)).toHaveValue("Zapatillas")
    for (const absent of [/stock inicial/i, /stock mínimo/i, /código de barras/i, /código de balanza/i, /^sku/i, /^precio/i, /^costo/i]) {
      expect(screen.queryByLabelText(absent)).not.toBeInTheDocument()
    }
    expect(screen.getByRole("button", { name: /actualizar producto/i })).toBeInTheDocument()
  })

  it("editar el padre manda los valores vigentes de lo que no muestra (compatibilidad con D1) y nunca precio ni costo", async () => {
    const legacyParent: Product = { ...PARENT, barcode: "7790001", sku: "PAD-1", minStock: 3 }
    productsList = [legacyParent, VARIANT]
    render(<ProductForm onSuccess={vi.fn()} initialData={legacyParent} />)
    fireEvent.change(screen.getByLabelText(/^nombre/i), { target: { value: "Zapatillas Pro" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))

    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    const sent = updateProductMock.mock.calls[0][0]
    expect(sent).toMatchObject({
      id: "parent-1", name: "Zapatillas Pro", stockControlType: "variant_only",
      price: 0, barcode: "7790001", sku: "PAD-1", minStock: 3,
    })
    expect("cost" in sent).toBe(false)
    // La unidad sin tocar viaja con su valor vigente (nunca otra): no cambia nada en el servidor.
    expect(sent.baseUnitId).toBe("u-kg")
  })

  it("variante → formulario de variante: sin selector de padre, categoría y unidad del padre en sólo lectura", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={VARIANT} />)
    expect(screen.queryByText(/producto padre \(variante\)/i)).not.toBeInTheDocument()
    expect(screen.queryByTestId("category-select")).not.toBeInTheDocument()
    expect(screen.getByTestId("inherited-category")).toHaveTextContent("Ropa")
    expect(screen.getByTestId("inherited-unit")).toHaveTextContent(/kilogramo/i)
    expect((screen.getByLabelText(/^sku/i) as HTMLInputElement).value).toBe("ZAP-41")
    expect(screen.getByRole("button", { name: /actualizar producto/i })).toBeInTheDocument()
  })

  it("editar la variante no manda categoría ni unidad (las hereda del padre)", async () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={VARIANT} />)
    fireEvent.change(screen.getByLabelText(/^nombre/i), { target: { value: "Zapatillas 42" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))

    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    const sent = updateProductMock.mock.calls[0][0]
    expect(sent).toMatchObject({ id: "var-1", name: "Zapatillas 42", parentId: "parent-1", isVariant: true, stockControlType: "tracked" })
    expect(sent.categoryId).toBeUndefined()
    expect(sent.baseUnitId).toBeUndefined()
  })

  it("producto tracked con variantes (armado a mano): formulario simple con el aviso y sin convertirse en padre", async () => {
    productsList = [HAND_MADE_PARENT, HAND_MADE_CHILD]
    render(<ProductForm onSuccess={vi.fn()} initialData={HAND_MADE_PARENT} />)

    expect(screen.getByText(/este producto tiene variantes/i)).toBeInTheDocument()
    expect((screen.getByLabelText(/código de barras/i) as HTMLInputElement).value).toBe("7790009")
    expect(screen.getByLabelText(/^precio/i)).toHaveValue(800)

    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))
    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    expect(updateProductMock.mock.calls[0][0]).toMatchObject({ stockControlType: "tracked", price: 800, barcode: "7790009" })
  })

  it("un producto simple sin variantes NO muestra el aviso", () => {
    productsList = [HAND_MADE_PARENT]
    render(<ProductForm onSuccess={vi.fn()} initialData={HAND_MADE_PARENT} />)
    expect(screen.queryByText(/este producto tiene variantes/i)).not.toBeInTheDocument()
  })
})

describe("sugerencia de precio (costo × 1,5)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    productsList = [PARENT, VARIANT]
    addProductMock.mockResolvedValue(undefined)
  })

  it("variante: escribir el costo completa el precio y la ayuda es visible", () => {
    render(<ProductForm onSuccess={vi.fn()} defaultParentId="parent-1" />)
    expect(screen.getByText(/costo × 1,5/i)).toBeInTheDocument()

    fireEvent.change(screen.getByLabelText(/^costo/i), { target: { value: "1000" } })
    expect(screen.getByLabelText(/^precio/i)).toHaveValue(1500)
  })

  it("un precio escrito a mano NO se pisa al cambiar el costo", () => {
    render(<ProductForm onSuccess={vi.fn()} defaultParentId="parent-1" />)
    fireEvent.change(screen.getByLabelText(/^costo/i), { target: { value: "1000" } })
    fireEvent.change(screen.getByLabelText(/^precio/i), { target: { value: "1700" } })
    fireEvent.change(screen.getByLabelText(/^costo/i), { target: { value: "2000" } })
    expect(screen.getByLabelText(/^precio/i)).toHaveValue(1700)
  })

  it("mientras el precio es la sugerencia, seguir ajustando el costo la actualiza", () => {
    render(<ProductForm onSuccess={vi.fn()} defaultParentId="parent-1" />)
    fireEvent.change(screen.getByLabelText(/^costo/i), { target: { value: "1000" } })
    fireEvent.change(screen.getByLabelText(/^costo/i), { target: { value: "2000" } })
    expect(screen.getByLabelText(/^precio/i)).toHaveValue(3000)
  })

  it("edición de un producto que ya trae precio: cambiar el costo no toca el precio", () => {
    render(<ProductForm onSuccess={vi.fn()} initialData={VARIANT} />)
    fireEvent.change(screen.getByLabelText(/^costo/i), { target: { value: "900" } })
    expect(screen.getByLabelText(/^precio/i)).toHaveValue(1000)
  })

  it("producto simple: también sugiere", async () => {
    const user = userEvent.setup()
    render(<ProductForm onSuccess={vi.fn()} />)
    await user.click(screen.getByRole("radio", { name: /producto simple/i }))
    await user.click(screen.getByRole("button", { name: /continuar/i }))
    fireEvent.change(screen.getByLabelText(/^costo/i), { target: { value: "400" } })
    expect(screen.getByLabelText(/^precio/i)).toHaveValue(600)
  })
})
