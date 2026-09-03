/**
 * productos-categorias-sku — ProductCatalog: búsqueda por SKU (grupo 13) y
 * selección múltiple + recategorización en lote (grupo 14, D14).
 *
 * Mocks espejo de product-catalog-search-collapse.test.tsx; el selector de
 * categoría y el diálogo de importación se mockean liviano (sus contratos
 * tienen tests propios).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, within } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

const toastSuccess = vi.fn()
const toastWarning = vi.fn()
const toastInfo = vi.fn()
const toastError = vi.fn()

vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ unitsById: new Map() }) }))
vi.mock("@/lib/format", () => ({ formatMoney: (n: number) => `$${n}` }))
vi.mock("@/lib/format-unit", () => ({ formatStock: (n: number) => `${n}` }))
vi.mock("@/lib/unit-utils", () => ({ resolveUnit: () => null }))
vi.mock("@/lib/excel", () => ({ exportToCSV: vi.fn() }))
vi.mock("sonner", () => ({
  toast: {
    success: (...a: unknown[]) => toastSuccess(...a),
    warning: (...a: unknown[]) => toastWarning(...a),
    info: (...a: unknown[]) => toastInfo(...a),
    error: (...a: unknown[]) => toastError(...a),
  },
}))
vi.mock("@/components/products/product-import-dialog", () => ({ ProductImportDialog: () => null }))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({
    productCategories: [
      { id: "cat-ropa",  accountId: "a", name: "Ropa",  isActive: true, sortOrder: 2, createdAt: "" },
      { id: "cat-hogar", accountId: "a", name: "Hogar", isActive: true, sortOrder: 4, createdAt: "" },
    ],
    isLoading: false,
  }),
}))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({
  ProductCategorySelect: ({ value, onChange }: { value: string | null; onChange: (v: string | null) => void }) => (
    <select data-testid="bulk-category-select" aria-label="Categoría destino" value={value ?? ""} onChange={(e) => onChange(e.target.value || null)}>
      <option value="">—</option>
      <option value="cat-ropa">Ropa</option>
      <option value="cat-hogar">Hogar</option>
    </select>
  ),
}))

const { ProductCatalog } = await import("@/components/products/product-catalog")

const parent: Product = {
  id: "parent-1", name: "Zapatillas Nike", category: "Ropa", categoryId: "cat-ropa",
  cost: 0, price: 100, margin: 0, stock: 0, minStock: 0, isVariant: false, stockControlType: "variant_only",
}
const child: Product = {
  id: "child-1", name: "Zapatillas Nike 41", category: "Ropa", categoryId: "cat-ropa", sku: "ZAP-41",
  cost: 50, price: 100, margin: 50, stock: 3, minStock: 1, isVariant: true, parentId: "parent-1", stockControlType: "tracked",
}
const aceite: Product = {
  id: "aceite", name: "Aceite de oliva", category: "Alimentos", categoryId: "cat-otros", sku: "ACE-500",
  cost: 10, price: 20, margin: 50, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
}
const yerba: Product = {
  id: "yerba", name: "Yerba mate", category: "Alimentos", categoryId: "cat-otros",
  cost: 10, price: 20, margin: 50, stock: 5, minStock: 1, isVariant: false, stockControlType: "tracked",
}

function renderCatalog(onBulkRecategorize = vi.fn().mockResolvedValue({ requested: 1, updated: 1 })) {
  render(
    <ProductCatalog
      products={[parent, child, aceite, yerba]}
      onAdd={vi.fn()}
      onAddVariant={vi.fn()}
      onEdit={vi.fn()}
      onDelete={vi.fn()}
      isAtLimit={false}
      onBulkRecategorize={onBulkRecategorize}
    />,
  )
  return { onBulkRecategorize }
}

function desktopTable() {
  return screen.getByRole("table")
}

describe("ProductCatalog — búsqueda por SKU (grupo 13)", () => {
  beforeEach(() => vi.clearAllMocks())

  it("encuentra un producto por su SKU, case-insensitive", () => {
    renderCatalog()
    fireEvent.change(screen.getByPlaceholderText(/buscar productos/i), { target: { value: "ace-500" } })

    const table = desktopTable()
    expect(within(table).getByText("Aceite de oliva")).toBeInTheDocument()
    expect(within(table).queryByText("Yerba mate")).not.toBeInTheDocument()
  })

  it("muestra el SKU cuando existe y no inventa uno cuando falta", () => {
    renderCatalog()
    const table = desktopTable()
    expect(within(table).getAllByText(/ACE-500/).length).toBeGreaterThan(0)
    const yerbaRow = within(table).getByText("Yerba mate").closest("tr")!
    expect(within(yerbaRow).queryByText(/SKU/i)).not.toBeInTheDocument()
  })

  it("una búsqueda que sólo matchea el SKU de una variante hija hace aparecer a su padre", () => {
    renderCatalog()
    fireEvent.change(screen.getByPlaceholderText(/buscar productos/i), { target: { value: "zap-41" } })

    const table = desktopTable()
    expect(within(table).getByText("Zapatillas Nike")).toBeInTheDocument()
    expect(within(table).queryByText("Aceite de oliva")).not.toBeInTheDocument()
  })

  it("búsqueda sin resultados", () => {
    renderCatalog()
    fireEvent.change(screen.getByPlaceholderText(/buscar productos/i), { target: { value: "no-existe" } })
    expect(within(desktopTable()).getByText(/no se encontraron productos/i)).toBeInTheDocument()
  })
})

describe("ProductCatalog — selección múltiple y lote (grupo 14)", () => {
  beforeEach(() => vi.clearAllMocks())

  it("selecciona/deselecciona padres y simples; las variantes no tienen casilla", () => {
    renderCatalog()
    const table = desktopTable()

    expect(screen.queryByText(/seleccionad/i)).not.toBeInTheDocument()
    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar aceite de oliva/i }))
    expect(screen.getByText(/1 seleccionado/i)).toBeInTheDocument()

    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar zapatillas nike$/i }))
    expect(screen.getByText(/2 seleccionados/i)).toBeInTheDocument()

    // expandir el grupo: la variante no ofrece casilla (su categoría es derivada)
    fireEvent.click(within(table).getByRole("button", { name: /expandir variantes/i }))
    expect(within(table).queryByRole("checkbox", { name: /zapatillas nike 41/i })).not.toBeInTheDocument()

    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar aceite de oliva/i }))
    expect(screen.getByText(/1 seleccionado/i)).toBeInTheDocument()
  })

  it("seleccionar todo lo filtrado y limpiar la selección al cambiar la búsqueda", () => {
    renderCatalog()
    const table = desktopTable()

    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar todos/i }))
    expect(screen.getByText(/3 seleccionados/i)).toBeInTheDocument()

    fireEvent.change(screen.getByPlaceholderText(/buscar productos/i), { target: { value: "yerba" } })
    expect(screen.queryByText(/seleccionad/i)).not.toBeInTheDocument()
  })

  it("la barra declara conteo y destino, pide confirmación, aplica, limpia y refresca", async () => {
    const { onBulkRecategorize } = renderCatalog(vi.fn().mockResolvedValue({ requested: 2, updated: 4 }))
    const table = desktopTable()

    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar aceite de oliva/i }))
    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar zapatillas nike$/i }))
    fireEvent.change(screen.getByTestId("bulk-category-select"), { target: { value: "cat-hogar" } })
    fireEvent.click(screen.getByRole("button", { name: /cambiar categoría/i }))

    const confirm = await screen.findByRole("alertdialog")
    expect(confirm).toHaveTextContent(/2 productos/)
    expect(confirm).toHaveTextContent(/Hogar/)
    fireEvent.click(within(confirm).getByRole("button", { name: /recategorizar/i }))

    await waitFor(() => expect(onBulkRecategorize).toHaveBeenCalledWith(["aceite", "parent-1"], "cat-hogar"))
    await waitFor(() => expect(toastSuccess).toHaveBeenCalledWith(expect.stringMatching(/4/)))
    expect(screen.queryByText(/seleccionad/i)).not.toBeInTheDocument()
  })

  it("sin categoría destino el botón está deshabilitado; cancelar la confirmación no aplica", async () => {
    const { onBulkRecategorize } = renderCatalog()
    fireEvent.click(within(desktopTable()).getByRole("checkbox", { name: /seleccionar aceite de oliva/i }))

    expect(screen.getByRole("button", { name: /cambiar categoría/i })).toBeDisabled()
    fireEvent.change(screen.getByTestId("bulk-category-select"), { target: { value: "cat-ropa" } })
    fireEvent.click(screen.getByRole("button", { name: /cambiar categoría/i }))
    const confirm = await screen.findByRole("alertdialog")
    fireEvent.click(within(confirm).getByRole("button", { name: /cancelar/i }))

    expect(onBulkRecategorize).not.toHaveBeenCalled()
    expect(screen.getByText(/1 seleccionado/i)).toBeInTheDocument()
  })

  it("informa el resultado real: 0 actualizados no es error; menos que lo solicitado avisa", async () => {
    const { onBulkRecategorize } = renderCatalog(vi.fn().mockResolvedValueOnce({ requested: 1, updated: 0 }).mockResolvedValueOnce({ requested: 2, updated: 1 }))
    const table = desktopTable()

    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar aceite de oliva/i }))
    fireEvent.change(screen.getByTestId("bulk-category-select"), { target: { value: "cat-ropa" } })
    fireEvent.click(screen.getByRole("button", { name: /cambiar categoría/i }))
    fireEvent.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: /recategorizar/i }))
    await waitFor(() => expect(onBulkRecategorize).toHaveBeenCalledTimes(1))
    await waitFor(() => expect(toastInfo).toHaveBeenCalledWith(expect.stringMatching(/ya ten/i)))
    expect(toastError).not.toHaveBeenCalled()

    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar aceite de oliva/i }))
    fireEvent.click(within(table).getByRole("checkbox", { name: /seleccionar yerba mate/i }))
    fireEvent.change(screen.getByTestId("bulk-category-select"), { target: { value: "cat-ropa" } })
    fireEvent.click(screen.getByRole("button", { name: /cambiar categoría/i }))
    fireEvent.click(within(await screen.findByRole("alertdialog")).getByRole("button", { name: /recategorizar/i }))
    await waitFor(() => expect(toastWarning).toHaveBeenCalledWith(expect.stringMatching(/1 de 2|no se pudo/i)))
  })

  it("a11y: las casillas tienen nombre accesible y la barra anuncia el conteo", () => {
    renderCatalog()
    fireEvent.click(within(desktopTable()).getByRole("checkbox", { name: /seleccionar yerba mate/i }))
    const bar = screen.getByRole("region", { name: /acciones en lote/i })
    expect(bar).toHaveAttribute("aria-live", "polite")
    expect(bar).toHaveTextContent(/1 seleccionado/)
  })
})
