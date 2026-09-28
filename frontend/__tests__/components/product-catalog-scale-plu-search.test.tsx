/**
 * balanza-etiquetas-pos (task 10.3 RED→GREEN) — búsqueda EXACTA por código de
 * balanza (scalePlu) en `ProductCatalog` (D2): escribir "509" encuentra el
 * producto con PLU 509; "50" (subcadena) NO lo encuentra por PLU. El predicado
 * único (extraído de las 3 copias inline) sigue matcheando nombre/categoría/
 * código de barras/SKU/id por subcadena, sin cambios.
 *
 * Mismos mocks que product-catalog-search-collapse.test.tsx (mismo árbol).
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ productCategories: [], isLoading: false, createProductCategory: vi.fn() }),
}))
vi.mock("@/hooks/data/use-products", () => ({
  useImportProducts: () => ({
    importMutation: { mutateAsync: vi.fn() },
    invalidateImportData: vi.fn(),
  }),
}))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: { enabled: false, layouts: [] }, isLoading: false, isError: false, error: null }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => ({ isWriter: true, role: "owner", isLoading: false }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ unitsById: new Map() }),
}))
vi.mock("@/lib/format", () => ({ formatMoney: (n: number) => `$${n}` }))
vi.mock("@/lib/format-unit", () => ({ formatStock: (n: number) => `${n}` }))
vi.mock("@/lib/unit-utils", () => ({ resolveUnit: () => null }))
vi.mock("@/lib/excel", () => ({ exportToCSV: vi.fn() }))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: { id: "u", email: "e@e.com" },
    profile: { plan: "gratis", billing_plan: "gratis" },
    loading: false,
  }),
  AuthProvider: ({ children }: { children: React.ReactNode }) => children,
}))

const TOMATE = "Tomate"
const PAPA = "Papa"

const tomate: Product = {
  id: "p-tomate", name: TOMATE, category: "Verdulería",
  cost: 2, price: 4.8, margin: 40, stock: 10, minStock: 0,
  isVariant: false, stockControlType: "tracked", scalePlu: 509,
}
const papa: Product = {
  id: "p-papa", name: PAPA, category: "Verdulería",
  cost: 5, price: 10, margin: 50, stock: 3, minStock: 0,
  isVariant: false, stockControlType: "tracked", scalePlu: 5091,
}

const { ProductCatalog } = await import("@/components/products/product-catalog")

function renderCatalog() {
  render(
    <ProductCatalog
      products={[tomate, papa]}
      onAdd={vi.fn()}
      onEdit={vi.fn()}
      onAddVariant={vi.fn()}
      onDelete={async () => {}}
      isAtLimit={false}
    />,
  )
}

function search(term: string) {
  fireEvent.change(screen.getByPlaceholderText(/buscar productos/i), { target: { value: term } })
}

describe("ProductCatalog — búsqueda exacta por Código de balanza (D2)", () => {
  it('"509" encuentra el producto con ese PLU exacto', () => {
    renderCatalog()
    search("509")
    expect(screen.getAllByText(TOMATE).length).toBeGreaterThan(0)
    expect(screen.queryAllByText(PAPA)).toHaveLength(0)
  })

  it('"50" NO encuentra nada por PLU (no es subcadena para scalePlu)', () => {
    renderCatalog()
    search("50")
    expect(screen.queryAllByText(TOMATE)).toHaveLength(0)
    expect(screen.queryAllByText(PAPA)).toHaveLength(0)
  })

  it("la búsqueda por nombre sigue funcionando (subcadena, sin relación con PLU)", () => {
    renderCatalog()
    search("tom")
    expect(screen.getAllByText(TOMATE).length).toBeGreaterThan(0)
    expect(screen.queryAllByText(PAPA)).toHaveLength(0)
  })
})
