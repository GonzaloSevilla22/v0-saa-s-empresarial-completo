/**
 * productos-padre-variantes (task 11.2) — cableado de /productos:
 *
 *  - «Modificar precios» (onBulkAdjustPrices) sólo se le pasa al catálogo con
 *    CAN_CONFIGURE (dueño/administrador);
 *  - «Nuevo producto» abre el paso «¿Qué querés crear?»;
 *  - «Nueva variante» (desde la fila del padre) abre el formulario de variante
 *    con el padre fijo.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

let currentRoles: string[] = ["owner"]
const adjustMock = vi.fn()

const PARENT: Product = {
  id: "parent-1", name: "Zapatillas", category: "Ropa", categoryId: "cat-ropa",
  cost: null, price: 0, margin: null, stock: 0, minStock: 0, isVariant: false, stockControlType: "variant_only",
}

vi.mock("next/navigation", () => ({ useSearchParams: () => new URLSearchParams() }))
vi.mock("@tanstack/react-query", () => ({ useQueryClient: () => ({ invalidateQueries: vi.fn() }) }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ user: { role: "member" } }) }))
vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => ({ role: currentRoles[0], roles: currentRoles, rolesResolved: true, isWriter: true, isLoading: false }),
}))
vi.mock("@/hooks/data/use-products", () => ({
  useProducts: () => ({ products: [PARENT], deleteProduct: vi.fn(), bulkSetCategory: vi.fn(), addProduct: vi.fn(), updateProduct: vi.fn() }),
  useBulkAdjustPrices: () => ({ adjust: adjustMock, mutation: {} }),
  useRelabelProductUnit: () => ({ relabel: vi.fn(), mutation: {} }),
}))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: { maxProducts: 1000 } }) }))
vi.mock("@/hooks/auth/use-plan-gate", () => ({ usePlanGate: () => ({ hasAccess: false }) }))
vi.mock("@/components/admin/ModuleMetricsWrapper", () => ({ ModuleMetricsWrapper: () => null }))
vi.mock("@/components/ai/PriceSuggestionModal", () => ({ PriceSuggestionModal: () => null }))
vi.mock("@/hooks/use-units-of-measure", () => ({ useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }) }))
vi.mock("@/hooks/use-barcode-scanner", () => ({ useBarcodeScanner: () => undefined }))
vi.mock("@/hooks/data/use-scale-settings", () => ({
  useScaleSettings: () => ({ settings: { enabled: false, layouts: [] }, isLoading: false, isError: false, error: null }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))
vi.mock("@/components/product-categories/ProductCategorySelect", () => ({ ProductCategorySelect: () => null }))
// El catálogo tiene sus propios tests: acá sólo importa QUÉ props le pasa la pantalla.
vi.mock("@/components/products/product-catalog", () => ({
  ProductCatalog: (props: {
    onAdd: () => void
    onAddVariant: (p: Product) => void
    onBulkAdjustPrices?: unknown
  }) => (
    <div>
      <button type="button" onClick={props.onAdd}>nuevo</button>
      <button type="button" onClick={() => props.onAddVariant(PARENT)}>nueva variante</button>
      {props.onBulkAdjustPrices ? <span data-testid="price-action">precios habilitados</span> : null}
    </div>
  ),
}))

const { default: ProductosPage } = await import("@/app/(dashboard)/productos/page")

describe("/productos — cableado de la tanda B", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    currentRoles = ["owner"]
  })

  it.each([["owner"], ["admin"]])("el rol %s recibe «Modificar precios»", (role) => {
    currentRoles = [role]
    render(<ProductosPage />)
    expect(screen.getByTestId("price-action")).toBeInTheDocument()
  })

  it.each([["seller"], ["cashier"], ["stock"], ["purchases"], ["accountant"]])(
    "el rol %s NO recibe «Modificar precios»",
    (role) => {
      currentRoles = [role]
      render(<ProductosPage />)
      expect(screen.queryByTestId("price-action")).not.toBeInTheDocument()
    },
  )

  it("«Nuevo producto» abre el paso «¿Qué querés crear?»", async () => {
    render(<ProductosPage />)
    fireEvent.click(screen.getByRole("button", { name: "nuevo" }))
    expect(await screen.findByRole("radiogroup", { name: /qué querés crear/i })).toBeInTheDocument()
  })

  it("«Nueva variante» abre el formulario de variante con el padre fijo y sin el paso", async () => {
    render(<ProductosPage />)
    fireEvent.click(screen.getByRole("button", { name: "nueva variante" }))
    expect(await screen.findByText("Variante de:")).toBeInTheDocument()
    expect(screen.getByText("Zapatillas")).toBeInTheDocument()
    expect(screen.queryByRole("radiogroup")).not.toBeInTheDocument()
  })
})
