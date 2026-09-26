/**
 * ventas-unidades-conversion (tasks 6.1 / 6.2): toda cantidad de stock se
 * muestra con el símbolo de la unidad base del producto — "0.550 kg" para un
 * producto en kilos, "12 uds" para uno por unidades — en el listado de stock
 * y en el historial de movimientos, con el mismo formateador que el catálogo.
 */
import { describe, expect, it, vi } from "vitest"
import { render, screen } from "@testing-library/react"

vi.mock("next/navigation", () => ({ useSearchParams: () => new URLSearchParams() }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ isAdmin: false, user: null }) }))
vi.mock("@/hooks/data/use-products", () => ({ useProducts: () => ({ products: [] }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: null }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }),
}))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ from: () => ({ select: () => ({ order: () => ({ range: async () => ({ data: [], error: null }) }) }) }) }),
}))
// La página importa ProductForm → hooks que cargan python-client, que tira al
// importar sin NEXT_PUBLIC_BACKEND_URL (mismo motivo que en los tests de los
// formularios). Acá no se renderiza la página: sólo sus columnas.
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ data: [], isLoading: false }),
  useDefaultProductCategory: () => ({ data: null }),
  mapProductCategory: (r: unknown) => r,
}))

import { buildColumns } from "@/app/(dashboard)/stock/page"
import { MovementRow } from "@/components/stock/stock-movements-panel"
import type { Product, StockMovement } from "@/lib/types"

function product(overrides: Partial<Product>): Product {
  return {
    id: "p1",
    name: "Tomate",
    category: "Verdulería",
    price: 1000,
    cost: 600,
    stock: 0.55,
    minStock: 0.5,
    createdAt: "2026-09-24T00:00:00Z",
    stockControlType: "tracked",
    ...overrides,
  } as Product
}

function cellText(col: ReturnType<typeof buildColumns>[number], row: Product): string {
  const { container } = render(<>{col.cell(row)}</>)
  return container.textContent ?? ""
}

describe("/stock — columnas con la unidad base del producto (6.1)", () => {
  const unitSymbolFor = (row: Product) => (row.baseUnitId === "u-kg" ? "kg" : undefined)
  const cols = buildColumns(false, unitSymbolFor)
  const byKey = (k: string) => cols.find((c) => c.key === k)!

  it("producto en kilos: 0.550 kg / 0.500 kg y reposición en kg", () => {
    const row = product({ baseUnitId: "u-kg", stock: 0.55, minStock: 0.5 })
    expect(cellText(byKey("stock"), row)).toBe("0.550 kg")
    expect(cellText(byKey("minStock"), row)).toBe("0.500 kg")
    const low = product({ baseUnitId: "u-kg", stock: 0.4, minStock: 0.5 })
    expect(cellText(byKey("reponer"), low)).toBe("0.600 kg")
  })

  it("producto sin unidad base: 12 uds, sin decimales", () => {
    const row = product({ id: "p2", stock: 12, minStock: 5 })
    expect(cellText(byKey("stock"), row)).toBe("12 uds")
    expect(cellText(byKey("minStock"), row)).toBe("5 uds")
  })

  it("nunca 'uds' fijo sobre un producto en kilos", () => {
    const row = product({ baseUnitId: "u-kg", stock: 0.55, minStock: 0.5 })
    expect(cellText(byKey("stock"), row)).not.toContain("uds")
  })
})

describe("historial de movimientos — delta y antes/después con unidad (6.2)", () => {
  const movement: StockMovement = {
    id: "m1",
    userId: "u1",
    productId: "p1",
    productName: "Tomate",
    type: "sale",
    quantityDelta: -0.45,
    quantityBefore: 1,
    quantityAfter: 0.55,
    createdAt: "2026-09-24T12:00:00Z",
  }

  it("venta de 450 g sobre un producto en kilos: -0.450 kg y 1 kg → 0.550 kg", () => {
    render(<MovementRow m={movement} unitSymbol="kg" />)
    expect(screen.getByText("-0.450 kg")).toBeTruthy()
    expect(screen.getByText("1 kg")).toBeTruthy()
    expect(screen.getByText("0.550 kg")).toBeTruthy()
  })

  it("sin unidad base: el número tal cual, entero sin decimales", () => {
    render(<MovementRow m={{ ...movement, id: "m2", quantityDelta: 3, quantityBefore: 9, quantityAfter: 12, type: "purchase" }} />)
    expect(screen.getByText("+3")).toBeTruthy()
    expect(screen.getByText("12")).toBeTruthy()
  })
})
