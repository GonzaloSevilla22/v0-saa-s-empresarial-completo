/**
 * Tests for `KpiSummaryCard` (components/dashboard/KpiSummaryCard.tsx),
 * task 1.10 of `v4-visual-3d-refresh` Fase A: apply the "entrada de cards"
 * 2D micro-animation (components/motion/FadeIn) to each KPI card rendered
 * by `KpiSummaryBlock` (a CSS Grid — `data-testid="kpi-summary-block"`,
 * `grid-cols-2 md:grid-cols-3 xl:grid-cols-5`, per
 * `__tests__/KpiSummaryBlock.test.tsx`).
 *
 * `MotionList`/`MotionListItem` are NOT used here on purpose: they force an
 * extra wrapper `<div>` around every item, which would make that wrapper
 * (not the card) the direct grid child — breaking `grid-cols-*`/`col-span-*`
 * placement for a `display:grid` container. `FadeIn` wraps the CARD ITSELF
 * (one component, no shared container to break), so it stays the direct
 * grid child and `className` (which carries `col-span-2` for "Ticket
 * Promedio") is forwarded there instead of onto the inner `<Card>`.
 *
 * Cycle: RED (card isn't animated / className isn't on the direct grid
 * child) → GREEN → TRIANGULATE (content still renders + className/col-span
 * still lands on the direct child + animation settles) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { KpiSummaryCard } from "@/components/dashboard/KpiSummaryCard"
import { DollarSign } from "lucide-react"

describe("KpiSummaryCard", () => {
  it("still renders label, value and badge (task 1.10 must not change data/content)", () => {
    render(
      <KpiSummaryCard
        label="Ganancia Neta"
        value="$184.200"
        badge="+12%"
        tone="green"
        icon={DollarSign}
      />
    )
    expect(screen.getByText("Ganancia Neta")).toBeInTheDocument()
    expect(screen.getByText("$184.200")).toBeInTheDocument()
    expect(screen.getByText("+12%")).toBeInTheDocument()
  })

  // qa-integral-modulos G12 (H27): el valor lleva `truncate` — "Feria 46% /
  // S/C 45%" se cortaba en "…S/C …" sin ninguna forma de leer el segundo
  // porcentaje. El span del valor expone el valor completo vía `title`
  // (tooltip nativo accesible), en todas las tarjetas.
  it("el valor truncable expone el texto completo en title (G12/H27)", () => {
    render(
      <KpiSummaryCard
        label="Margen por Canal"
        value="Feria 46% / S/C 45%"
        badge="Feria lidera"
        tone="green"
        icon={DollarSign}
      />
    )
    const value = screen.getByText("Feria 46% / S/C 45%")
    expect(value).toHaveAttribute("title", "Feria 46% / S/C 45%")
  })

  // ── Regression guard: className (col-span-2 for "Ticket Promedio" in
  // KpiSummaryBlock) must land on the outermost/direct grid child, not get
  // stranded on an inner element, or the CSS Grid placement breaks. ──
  it("forwards className to the outermost element (stays the direct grid child)", () => {
    const { container } = render(
      <KpiSummaryCard
        label="Ticket Promedio"
        value="$6.820"
        badge="+5%"
        tone="green"
        icon={DollarSign}
        className="col-span-2 md:col-span-1 xl:col-span-1"
      />
    )
    const outermost = container.firstElementChild as HTMLElement
    expect(outermost.className).toContain("col-span-2")

    // The rounded-xl Card must be a DESCENDANT of the col-span-2 wrapper
    // (not a sibling, not the same node re-used by coincidence) — otherwise
    // col-span-2 would be floating on an unrelated node and the grid
    // placement would be broken.
    const card = screen.getByText("Ticket Promedio").closest("[class*='rounded-xl']")
    expect(card).not.toBeNull()
    expect(outermost.contains(card)).toBe(true)
    expect(outermost).not.toBe(card)
  })

  // ── RED/GREEN + TRIANGULATE: entrance animation settles ──
  it("settles fully visible (entrada de cards, task 1.10)", async () => {
    render(
      <KpiSummaryCard
        label="Ganancia Neta"
        value="$184.200"
        badge="+12%"
        tone="green"
        icon={DollarSign}
      />
    )
    const outermost = screen.getByText("Ganancia Neta").closest('[style*="opacity"]') as HTMLElement
    await waitFor(() => expect(outermost).toHaveStyle({ opacity: "1" }), { timeout: 2000 })
  })
})
