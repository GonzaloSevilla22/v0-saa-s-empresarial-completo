/**
 * ProductCatalog — searching must NOT auto-expand matching variant groups.
 * Parents stay collapsed until the user toggles them open (same as the
 * no-search view). Regression guard for the auto-expand-on-search behaviour.
 *
 * Cycle: RED → GREEN → TRIANGULATE. Mocks mirror plan-gate-price-suggestion.test.tsx.
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"
import type { Product } from "@/lib/types"

// ─── Mocks ─────────────────────────────────────────────────────────────────
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

// ─── Fixtures ──────────────────────────────────────────────────────────────
const PARENT = "Remera Afa By Clisa"
const CHILD = "Remera Afa By Clisa Talle 2 Celeste"

const parent: Product = {
  id: "parent-1", name: PARENT, category: "Ropa",
  cost: 0, price: 16529, margin: 0, stock: 0, minStock: 0,
  isVariant: false, stockControlType: "tracked",
}
const child: Product = {
  id: "child-1", name: CHILD, category: "Ropa",
  cost: 6600, price: 16529, margin: 60, stock: 0, minStock: 0,
  isVariant: true, parentId: "parent-1", stockControlType: "tracked",
}

async function renderCatalog() {
  const { ProductCatalog } = await import("@/components/products/product-catalog")
  render(
    <ProductCatalog
      products={[parent, child]}
      onAdd={vi.fn()}
      onEdit={vi.fn()}
      onAddVariant={vi.fn()}
      onDelete={async () => {}}
      isAtLimit={false}
    />,
  )
}

function search(term: string) {
  fireEvent.change(screen.getByPlaceholderText(/buscar productos/i), {
    target: { value: term },
  })
}

// ─── Tests ──────────────────────────────────────────────────────────────────
describe("ProductCatalog — search keeps variant groups collapsed", () => {
  // ── RED → GREEN: parent-name match stays collapsed ───────────────────────
  it("does not auto-expand a matching group when searching (variants hidden)", async () => {
    await renderCatalog()
    search("Remera Afa")

    expect(screen.getAllByText(PARENT).length).toBeGreaterThan(0) // group is shown
    expect(screen.queryAllByText(CHILD)).toHaveLength(0)          // …but collapsed
  })

  // ── TRIANGULATE: child-only match still surfaces the (collapsed) parent ──
  it("surfaces a group when only a child matches, still collapsed", async () => {
    await renderCatalog()
    search("Celeste")

    expect(screen.getAllByText(PARENT).length).toBeGreaterThan(0)
    expect(screen.queryAllByText(CHILD)).toHaveLength(0)
  })

  // ── TRIANGULATE: manual expand still works after searching ───────────────
  it("expands the group on demand after searching", async () => {
    await renderCatalog()
    search("Remera Afa")
    expect(screen.queryAllByText(CHILD)).toHaveLength(0)

    fireEvent.click(screen.getAllByLabelText(/expandir variantes/i)[0])
    expect(screen.getAllByText(CHILD).length).toBeGreaterThan(0)
  })
})
