/**
 * productos-padre-variantes (task 10.1/10.2) — «Corregir unidad» en los
 * formularios de padre y de producto simple:
 *
 *  - con stock en la familia el selector libre se REEMPLAZA por la acción;
 *  - sin stock el selector de siempre sigue ahí (y no hay acción);
 *  - sólo dueño y administrador (CAN_CONFIGURE) ven la acción;
 *  - tras corregir, el formulario adopta la unidad nueva (no re-envía la vieja).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"
import type { Product, UnitOfMeasure } from "@/lib/types"

const updateProductMock = vi.fn()
let currentRoles: string[] = ["owner"]
let productsList: Product[] = []

const KG: UnitOfMeasure = { id: "u-kg", name: "Kilogramo", symbol: "kg", type: "weight", factor: 1, isSystem: true }
const UN: UnitOfMeasure = { id: "u-un", name: "Unidad", symbol: "u", type: "unit", factor: 1, isSystem: true }

vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: currentRoles[0], roles: currentRoles, rolesResolved: true, isWriter: true, isLoading: false }),
}))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: productsList, addProduct: vi.fn(), updateProduct: updateProductMock }),
}))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [UN, KG], unitsById: new Map([[UN.id, UN], [KG.id, KG]]) }),
}))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/lib/barcode-utils", () => ({ generateEAN13: () => "7790000000000" }))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: { enabled: false, layouts: [] }, isLoading: false, isError: false, error: null }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select aria-label="Categoría" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">—</option>
      <option value="cat-food">Alimentos</option>
    </select>
  ),
}))
// El diálogo tiene su propio test: acá sólo importa cuándo se abre y con qué.
vi.mock("@/components/products/RelabelUnitDialog", () => ({
  RelabelUnitDialog: (props: { product: Product; exampleQuantity: number; onDone?: (unitId: string) => void }) => (
    <div data-testid="relabel-dialog" data-product={props.product.id} data-example={props.exampleQuantity}>
      <button type="button" onClick={() => props.onDone?.("u-un")}>simular corrección</button>
    </div>
  ),
}))

const { ProductForm } = await import("@/components/forms/product-form")

const PARENT: Product = {
  id: "parent-1", name: "Harina", category: "Almacén", categoryId: "cat-food",
  cost: null, price: 0, margin: null, stock: 0, minStock: 0, isVariant: false,
  stockControlType: "variant_only", baseUnitId: "u-kg",
}
const CHILD_WITH_STOCK: Product = {
  id: "child-1", name: "Harina 1 kg", category: "Almacén", categoryId: "cat-food",
  cost: 100, price: 200, margin: 50, stock: 12, minStock: 1, isVariant: true, parentId: "parent-1", stockControlType: "tracked",
}
const CHILD_EMPTY: Product = { ...CHILD_WITH_STOCK, stock: 0 }
const SIMPLE_WITH_STOCK: Product = {
  id: "simple-1", name: "Tomate", category: "Verdulería", categoryId: "cat-food",
  cost: 500, price: 1000, margin: 50, stock: 7, minStock: 1, isVariant: false, stockControlType: "tracked", baseUnitId: "u-kg",
}

function hasUnitCombobox() {
  return screen.queryAllByRole("combobox").some((el) => /kilogramo|unidad|seleccionar unidad/i.test(el.textContent ?? ""))
}

describe("«Corregir unidad» — formulario del padre", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    currentRoles = ["owner"]
    updateProductMock.mockResolvedValue(undefined)
  })

  it("con stock en las variantes el selector libre se reemplaza por la acción", () => {
    productsList = [PARENT, CHILD_WITH_STOCK]
    render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)

    expect(screen.getByRole("button", { name: /corregir unidad/i })).toBeInTheDocument()
    expect(screen.getByTestId("current-unit")).toHaveTextContent(/kilogramo/i)
    expect(hasUnitCombobox()).toBe(false)
  })

  it("abre el diálogo con el producto y el stock real de la familia como ejemplo", async () => {
    productsList = [PARENT, CHILD_WITH_STOCK]
    render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)
    await userEvent.setup().click(screen.getByRole("button", { name: /corregir unidad/i }))

    const dialog = await screen.findByTestId("relabel-dialog")
    expect(dialog).toHaveAttribute("data-product", "parent-1")
    expect(dialog).toHaveAttribute("data-example", "12")
  })

  it("sin stock en la familia el selector de siempre sigue ahí y no hay acción", () => {
    productsList = [PARENT, CHILD_EMPTY]
    render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)

    expect(screen.queryByRole("button", { name: /corregir unidad/i })).not.toBeInTheDocument()
    expect(hasUnitCombobox()).toBe(true)
  })

  it.each([["admin"], ["owner"]])("el rol %s ve la acción", (role) => {
    currentRoles = [role]
    productsList = [PARENT, CHILD_WITH_STOCK]
    render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)
    expect(screen.getByRole("button", { name: /corregir unidad/i })).toBeInTheDocument()
  })

  it.each([["cashier"], ["seller"], ["stock"], ["accountant"]])(
    "el rol %s NO ve la acción: ve la unidad en sólo lectura y quién la corrige",
    (role) => {
      currentRoles = [role]
      productsList = [PARENT, CHILD_WITH_STOCK]
      render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)

      expect(screen.queryByRole("button", { name: /corregir unidad/i })).not.toBeInTheDocument()
      expect(screen.getByTestId("current-unit")).toHaveTextContent(/kilogramo/i)
      expect(screen.getByText(/la corrige un administrador o el dueño/i)).toBeInTheDocument()
      expect(hasUnitCombobox()).toBe(false)
    },
  )

  it("tras corregir, guardar el nombre manda la unidad NUEVA (no la que tenía al abrir)", async () => {
    productsList = [PARENT, CHILD_WITH_STOCK]
    render(<ProductForm onSuccess={vi.fn()} initialData={PARENT} />)
    await userEvent.setup().click(screen.getByRole("button", { name: /corregir unidad/i }))
    fireEvent.click(await screen.findByRole("button", { name: /simular corrección/i }))

    fireEvent.change(screen.getByLabelText(/^nombre/i), { target: { value: "Harina 000" } })
    fireEvent.click(screen.getByRole("button", { name: /actualizar producto/i }))

    await waitFor(() => expect(updateProductMock).toHaveBeenCalledTimes(1))
    expect(updateProductMock.mock.calls[0][0]).toMatchObject({ name: "Harina 000", baseUnitId: "u-un" })
  })
})

describe("«Corregir unidad» — producto simple", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    currentRoles = ["owner"]
    updateProductMock.mockResolvedValue(undefined)
  })

  it("con stock el selector se reemplaza por la acción", () => {
    productsList = [SIMPLE_WITH_STOCK]
    render(<ProductForm onSuccess={vi.fn()} initialData={SIMPLE_WITH_STOCK} />)
    expect(screen.getByRole("button", { name: /corregir unidad/i })).toBeInTheDocument()
    expect(screen.getByTestId("current-unit")).toHaveTextContent(/kilogramo/i)
  })

  it("con stock y rol de depósito no hay acción", () => {
    currentRoles = ["stock"]
    productsList = [SIMPLE_WITH_STOCK]
    render(<ProductForm onSuccess={vi.fn()} initialData={SIMPLE_WITH_STOCK} />)
    expect(screen.queryByRole("button", { name: /corregir unidad/i })).not.toBeInTheDocument()
  })

  it("sin stock conserva el selector de unidad y no ofrece la acción", () => {
    const empty = { ...SIMPLE_WITH_STOCK, stock: 0 }
    productsList = [empty]
    render(<ProductForm onSuccess={vi.fn()} initialData={empty} />)
    expect(screen.queryByRole("button", { name: /corregir unidad/i })).not.toBeInTheDocument()
    expect(hasUnitCombobox()).toBe(true)
  })

  it("el alta de un producto simple nunca ofrece la acción", () => {
    productsList = []
    render(<ProductForm onSuccess={vi.fn()} initialKind="simple" />)
    expect(screen.queryByRole("button", { name: /corregir unidad/i })).not.toBeInTheDocument()
  })
})
