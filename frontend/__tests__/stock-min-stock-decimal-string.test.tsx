/**
 * Corrección del PR #584 (hallazgo bloqueante 3): `/stock` se caía en prod.
 *
 * FastAPI serializa `min_stock` (Decimal, `numeric(15,4)` desde la migración de
 * unidades) como STRING — `"0.5000"`, `"5.0000"` — igual que `stock`, `price`
 * y `cost`. El hook lo mapeaba sin `Number()` y la columna "Stock mínimo"
 * terminaba en `"5.0000".toFixed(3)` → TypeError en cada fila. Los tests
 * previos no lo veían porque sus fixtures traían `min_stock` como número.
 *
 * Estos tests usan la forma REAL de la fila de `GET /products` (strings
 * decimales) y recorren hook → columna, sin mockear el mapeo.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("next/navigation", () => ({ useSearchParams: () => new URLSearchParams() }))
vi.mock("@/contexts/auth-context", () => ({ useAuth: () => ({ isAdmin: false, user: null }) }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => ({ branches: [] }) }))
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => ({ limits: null }) }))
vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ units: [], unitsById: new Map() }),
}))
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ from: () => ({ select: () => ({ order: () => ({ range: async () => ({ data: [], error: null }) }) }) }) }),
}))
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/hooks/data/use-product-categories", () => ({
  useProductCategories: () => ({ data: [], isLoading: false }),
  useDefaultProductCategory: () => ({ data: null }),
  mapProductCategory: (r: unknown) => r,
}))

import { pythonClient } from "@/lib/api/python-client"
import { useProducts } from "@/hooks/data/use-products"
import { buildColumns, buildMobileCard } from "@/app/(dashboard)/stock/page"
import type { Product } from "@/lib/types"

/** Fila tal como la serializa FastAPI (Pydantic v2: Decimal → string). */
const API_ROW_KG = {
  id: "prod-kg",
  account_id: "acc-1",
  name: "Tomate",
  category: "Verdulería",
  category_id: null,
  price: "1000.00",
  cost: "600.00",
  stock: "0.5500",
  min_stock: "0.5000",
  barcode: null,
  sku: null,
  is_variant: false,
  stock_control_type: "tracked",
  created_at: "2026-09-24T00:00:00Z",
  parent_id: null,
  base_unit_id: "u-kg",
}

const API_ROW_UDS = {
  ...API_ROW_KG,
  id: "prod-uds",
  name: "Bolsa",
  stock: "12.0000",
  min_stock: "5.0000",
  base_unit_id: null,
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

async function loadProducts(rows: unknown[]): Promise<Product[]> {
  vi.mocked(pythonClient.get).mockResolvedValue(rows)
  const { result } = renderHook(() => useProducts(), { wrapper: makeWrapper() })
  await waitFor(() => expect(result.current.products).toHaveLength(rows.length))
  return result.current.products
}

describe("useProducts — min_stock llega como string decimal de FastAPI", () => {
  beforeEach(() => vi.clearAllMocks())

  it("mapea \"0.5000\" a 0.5 (número) y \"5.0000\" a 5", async () => {
    const [kg, uds] = await loadProducts([API_ROW_KG, API_ROW_UDS])
    expect(kg.minStock).toBe(0.5)
    expect(uds.minStock).toBe(5)
  })

  it("min_stock null → 0 (sin umbral), nunca NaN", async () => {
    const [p] = await loadProducts([{ ...API_ROW_UDS, min_stock: null }])
    expect(p.minStock).toBe(0)
  })
})

describe("/stock — columna 'Stock mínimo' con una fila real del API", () => {
  beforeEach(() => vi.clearAllMocks())

  const unitSymbolFor = (row: Product) => (row.baseUnitId === "u-kg" ? "kg" : undefined)

  function cellText(node: React.ReactNode): string {
    const { container } = render(<>{node}</>)
    return container.textContent ?? ""
  }

  it("desktop: renderiza '0.500 kg' y '5 uds' sin lanzar", async () => {
    const [kg, uds] = await loadProducts([API_ROW_KG, API_ROW_UDS])
    const minCol = buildColumns(false, unitSymbolFor).find((c) => c.key === "minStock")!
    expect(cellText(minCol.cell(kg))).toBe("0.500 kg")
    expect(cellText(minCol.cell(uds))).toBe("5 uds")
  })

  it("mobile: la tarjeta muestra stock / mínimo sin lanzar", async () => {
    const [kg] = await loadProducts([API_ROW_KG])
    const card = buildMobileCard(unitSymbolFor)
    expect(cellText(card(kg))).toContain("0.500 kg")
  })
})
