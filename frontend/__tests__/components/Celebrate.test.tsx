/**
 * Tests for the `Celebrate` motion wrapper (components/motion/Celebrate.tsx),
 * task 1.5/1.6/1.7 of `v4-visual-3d-refresh` Fase A. Used for 2D feedback of
 * success/hito moments (e.g. venta cerrada) — the 3D burst equivalent is
 * Fase C, out of scope here.
 *
 * Same real-wiring approach as FadeIn.test.tsx/MotionList.test.tsx: real
 * `usePrefersReducedMotion` hook (matchMedia stubbed), real variants from
 * `components/motion/variants.ts`, settled-state assertions via `waitFor`
 * (see the GOTCHA documented in variants.ts).
 *
 * Cycle: RED (Celebrate.tsx doesn't exist yet) → GREEN → TRIANGULATE (full
 * motion vs reduced motion, show=false renders nothing) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { Celebrate } from "@/components/motion/Celebrate"

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

describe("Celebrate", () => {
  it("renders nothing when show is false", () => {
    installMatchMediaStub(false)
    render(
      <Celebrate show={false}>
        <p>venta cerrada</p>
      </Celebrate>
    )
    expect(screen.queryByText("venta cerrada")).not.toBeInTheDocument()
  })

  // ── RED/GREEN: happy path — starts scaled down, settles fully visible ──
  // Note: like FadeIn, the settled transform for the full-motion case
  // normalizes to "none" (Framer Motion elides a scale(1) at rest), so the
  // meaningful scale assertion is on the initial hidden frame, not the
  // settled one.
  it("renders its children scaled down initially, and settles fully visible when show is true and motion is enabled", async () => {
    installMatchMediaStub(false)
    render(
      <Celebrate show={true}>
        <p>venta cerrada</p>
      </Celebrate>
    )

    const wrapper = screen.getByText("venta cerrada").parentElement as HTMLElement
    expect(wrapper.style.opacity).toBe("0")
    expect(wrapper.style.transform).toContain("scale(0.85)")

    await waitFor(() =>
      expect(screen.getByText("venta cerrada").parentElement?.style.opacity).toBe("1")
    )
  })

  // ── TRIANGULATE: edge case — reduced motion settles with no scale transform ──
  it("settles fully visible with no scale transform when the OS requests prefers-reduced-motion: reduce", async () => {
    installMatchMediaStub(true)
    render(
      <Celebrate show={true}>
        <p>meta alcanzada</p>
      </Celebrate>
    )

    await waitFor(() =>
      expect(screen.getByText("meta alcanzada").parentElement?.style.opacity).toBe("1")
    )
    // Regression guard (same gotcha as FadeIn/MotionList): no residual scale
    // transform once reduced-motion is confirmed.
    expect(screen.getByText("meta alcanzada").parentElement?.style.transform).not.toContain(
      "scale(0"
    )
  })
})
