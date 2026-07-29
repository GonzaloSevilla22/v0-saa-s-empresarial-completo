/**
 * Tests for `Poster` (components/three/Poster.tsx) — the single static
 * fallback art used for every 3D surface state: `next/dynamic`'s `loading`,
 * the `<Suspense>` fallback while assets load, the capability-gate
 * disqualified state, and the `SceneErrorBoundary` fallback (spec
 * `immersive-3d-surfaces`).
 *
 * Cycle: RED (component doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { Poster } from "@/components/three/Poster"

describe("Poster", () => {
  // ── RED/GREEN: happy path — single theme-agnostic poster ────────────────
  it("renders a single decorative, aria-hidden image when no dark variant is given", () => {
    const { container } = render(<Poster src="/3d/hero-poster.svg" width={640} height={480} />)

    const wrapper = container.firstElementChild as HTMLElement
    expect(wrapper).toHaveAttribute("aria-hidden", "true")

    const images = screen.getAllByRole("presentation", { hidden: true })
    expect(images).toHaveLength(1)
    expect(images[0]).toHaveAttribute("alt", "")
  })

  // ── TRIANGULATE: theme-aware — renders both variants, CSS toggles visibility ──
  it("renders both light and dark variants (CSS-toggled) when srcDark is given", () => {
    render(
      <Poster
        src="/3d/hero-poster-light.svg"
        srcDark="/3d/hero-poster-dark.svg"
        width={640}
        height={480}
      />,
    )

    const images = screen.getAllByRole("presentation", { hidden: true })
    expect(images).toHaveLength(2)
    expect(images[0].className).toContain("dark:hidden")
    expect(images[1].className).toContain("dark:block")
  })
})
