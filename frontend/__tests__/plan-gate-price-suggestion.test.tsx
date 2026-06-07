/**
 * Integration test: "Sugerir precio IA" button visibility based on plan.
 * (task 5.6)
 *
 * Verifies that the button is absent from the DOM when the user's plan is
 * 'gratis' (i.e., `onSuggestPrice` prop is undefined in ProductCatalog).
 *
 * Requires: vitest + @testing-library/react + jsdom (same setup as
 * PriceSuggestionModal.test.tsx).
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

// ─── Minimal mock data ─────────────────────────────────────────────────────

import type { Product } from "@/lib/types"

const mockProduct: Product = {
  id:               "prod-001",
  name:             "Remera básica",
  category:         "Ropa",
  cost:             500,
  price:            1200,
  margin:           58,
  stock:            10,
  minStock:         2,
  isVariant:        false,
  stockControlType: "tracked",
}

// ─── Mocks ─────────────────────────────────────────────────────────────────

vi.mock("@/hooks/use-units-of-measure", () => ({
  useUnitsOfMeasure: () => ({ unitsById: new Map() }),
}))

vi.mock("@/lib/format", () => ({
  formatMoney: (n: number) => `$${n}`,
}))

vi.mock("@/lib/format-unit", () => ({
  formatStock: (n: number) => `${n}`,
}))

vi.mock("@/lib/unit-utils", () => ({
  resolveUnit: () => null,
}))

vi.mock("@/lib/excel", () => ({
  exportToCSV: vi.fn(),
}))

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}))

// ProductImportDialog uses useAuth — mock the entire context to avoid AuthProvider requirement
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({
    user: { id: "test-user-id", email: "test@example.com" },
    profile: { plan: "gratis", billing_plan: "gratis" },
    loading: false,
  }),
  AuthProvider: ({ children }: { children: React.ReactNode }) => children,
}))

// ─── Tests ──────────────────────────────────────────────────────────────────

describe("ProductCatalog — plan gate for price suggestion (task 5.6)", () => {
  it("'Precio IA' button is NOT in the DOM when onSuggestPrice is undefined (gratis plan)", async () => {
    const { ProductCatalog } = await import("@/components/products/product-catalog")

    render(
      <ProductCatalog
        products={[mockProduct]}
        onAdd={vi.fn()}
        onEdit={vi.fn()}
        onAddVariant={vi.fn()}
        onDelete={async () => {}}
        isAtLimit={false}
        // onSuggestPrice is intentionally NOT passed → gratis plan behaviour
      />
    )

    // The button title is "Sugerir precio IA" — it must not be present
    const button = screen.queryByTitle("Sugerir precio IA")
    expect(button).not.toBeInTheDocument()
  })

  it("'Precio IA' button IS in the DOM when onSuggestPrice is provided (avanzado plan)", async () => {
    const { ProductCatalog } = await import("@/components/products/product-catalog")
    const onSuggestPrice = vi.fn()

    render(
      <ProductCatalog
        products={[mockProduct]}
        onAdd={vi.fn()}
        onEdit={vi.fn()}
        onAddVariant={vi.fn()}
        onDelete={async () => {}}
        isAtLimit={false}
        onSuggestPrice={onSuggestPrice}
      />
    )

    // In the desktop table there should be at least one button with this title
    const buttons = screen.getAllByTitle("Sugerir precio IA")
    expect(buttons.length).toBeGreaterThan(0)
  })
})
