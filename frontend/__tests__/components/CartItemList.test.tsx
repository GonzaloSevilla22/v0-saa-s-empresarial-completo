/**
 * Tests for `CartItemList` (components/shared/cart-item-list.tsx), task 1.10
 * of `v4-visual-3d-refresh` Fase A: apply the "entrada de listas" 2D
 * micro-animation (components/motion/MotionList) to this shared component —
 * used by POS (`app/(dashboard)/ventas/pos`) plus compras/gastos forms, all
 * classified `2d-motion` in `frontend/docs/surface-matrix.md`. Also migrates
 * the one hardcoded `amber-*` badge class here to the `warning` token
 * (task 1.9's mapping, found adjacent to this task's edit).
 *
 * Purely presentational: `onRemove`/`onUpdateQty` wiring must keep working
 * unchanged (task 1.10 explicitly forbids touching handlers/queries/
 * mutations) — those are the safety-net regression assertions. The motion
 * assertions follow the same real-wiring + settled-state approach as
 * FadeIn.test.tsx/MotionList.test.tsx (see the GOTCHA documented in
 * components/motion/variants.ts).
 *
 * Cycle: RED (rows aren't animated / badge still hardcoded) → GREEN →
 * TRIANGULATE (existing callbacks preserved + new animation settles +
 * multiple rows all animate) → REFACTOR.
 */

import { describe, it, expect, vi } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { CartItemList, type CartDisplayItem } from "@/components/shared/cart-item-list"

function installMatchMediaStub(matches: boolean) {
  window.matchMedia = (query: string): MediaQueryList =>
    ({
      matches,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList
}

const ITEMS: CartDisplayItem[] = [
  { id: "1", productName: "Producto A", quantity: 2, unitValue: 100, subtotal: 200 },
  { id: "2", productName: "Producto B", quantity: 1, unitValue: 50, subtotal: 50, badge: "kg · 10% desc." },
]

describe("CartItemList", () => {
  it("renders nothing when items is empty (unchanged existing behavior)", () => {
    installMatchMediaStub(false)
    const { container } = render(
      <CartItemList items={[]} onRemove={vi.fn()} onUpdateQty={vi.fn()} />
    )
    expect(container).toBeEmptyDOMElement()
  })

  // ── Safety net: existing onRemove/onUpdateQty wiring must survive the refactor ──
  it("still calls onRemove and onUpdateQty (task 1.10 must not touch handlers)", () => {
    installMatchMediaStub(false)
    const onRemove = vi.fn()
    const onUpdateQty = vi.fn()
    render(<CartItemList items={ITEMS} onRemove={onRemove} onUpdateQty={onUpdateQty} />)

    fireEvent.click(screen.getByLabelText("Eliminar Producto A"))
    expect(onRemove).toHaveBeenCalledWith("1")

    const qtyInput = screen.getByDisplayValue("2")
    fireEvent.change(qtyInput, { target: { value: "5" } })
    expect(onUpdateQty).toHaveBeenCalledWith("1", 5)
  })

  // ── RED/GREEN + TRIANGULATE: entrance animation settles for every row ──
  it("settles every cart row fully visible (entrada de listas, task 1.10)", async () => {
    installMatchMediaStub(false)
    render(<CartItemList items={ITEMS} onRemove={vi.fn()} onUpdateQty={vi.fn()} />)

    await waitFor(
      () => {
        expect(screen.getByText("Producto A").closest('[style*="opacity"]')).toHaveStyle({
          opacity: "1",
        })
        expect(screen.getByText("Producto B").closest('[style*="opacity"]')).toHaveStyle({
          opacity: "1",
        })
      },
      { timeout: 2000 }
    )
  })

  it("uses the warning token for the badge instead of the hardcoded amber classes", () => {
    installMatchMediaStub(false)
    render(<CartItemList items={ITEMS} onRemove={vi.fn()} onUpdateQty={vi.fn()} />)
    const badge = screen.getByText("kg · 10% desc.")
    expect(badge.className).toContain("bg-warning/15")
    expect(badge.className).toContain("text-warning")
    expect(badge.className).toContain("border-warning/25")
  })
})
