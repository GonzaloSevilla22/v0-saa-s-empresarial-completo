/**
 * Tests for the `FadeIn` motion wrapper (components/motion/FadeIn.tsx),
 * task 1.5/1.6/1.7 of `v4-visual-3d-refresh` Fase A.
 *
 * Verifies the real wiring end-to-end: `usePrefersReducedMotion` (real hook,
 * matchMedia stubbed like `__tests__/hooks/usePrefersReducedMotion.test.ts`)
 * drives which variants from `components/motion/variants.ts` framer-motion
 * applies to the DOM node. Not mocking the hook/variants on purpose — this
 * is what confirms task 1.6 ("cablearlo en las envolturas"), not just that
 * the pure builders in variants.ts work in isolation.
 *
 * Assertions target the *settled* state (`waitFor`), not the synchronous
 * post-render frame: `usePrefersReducedMotion` is SSR-safe and always
 * resolves `false` on the very first render before correcting asynchronously
 * (see hook docstring), so the immediate post-render frame is not a reliable
 * signal of the final reduced-motion behavior — see the GOTCHA documented in
 * `components/motion/variants.ts`, found while writing this test.
 *
 * Cycle: RED (FadeIn.tsx doesn't exist yet) → GREEN → TRIANGULATE (full
 * motion vs reduced motion) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import { FadeIn } from "@/components/motion/FadeIn"

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

describe("FadeIn", () => {
  // ── RED/GREEN: happy path — starts hidden with an offset, settles visible ──
  // Note: the settled transform for the full-motion case normalizes to
  // "none" (Framer Motion elides a zero-value translateY at rest), so the
  // meaningful translateY assertion is on the initial hidden frame, not the
  // settled one.
  it("renders its children, starts hidden with a translateY offset, and settles fully visible when motion is enabled", async () => {
    installMatchMediaStub(false)
    render(
      <FadeIn>
        <p>contenido</p>
      </FadeIn>
    )
    expect(screen.getByText("contenido")).toBeInTheDocument()

    const wrapper = screen.getByText("contenido").parentElement as HTMLElement
    expect(wrapper.style.opacity).toBe("0")
    expect(wrapper.style.transform).toContain("translateY")

    await waitFor(() => expect(wrapper.style.opacity).toBe("1"))
  })

  // ── TRIANGULATE: edge case — reduced motion settles with NO transform ──
  it("settles at full opacity with no leftover transform when the OS requests prefers-reduced-motion: reduce", async () => {
    installMatchMediaStub(true)
    render(
      <FadeIn>
        <p>contenido reducido</p>
      </FadeIn>
    )
    const wrapper = screen.getByText("contenido reducido").parentElement as HTMLElement
    await waitFor(() => expect(wrapper.style.opacity).toBe("1"))
    // Regression guard for the gotcha in variants.ts: the transient
    // full-motion mount frame (hook resolves async) must not leave a
    // residual translateY offset frozen once reduced-motion is confirmed.
    expect(wrapper.style.transform).not.toContain("translateY")
  })

  it("forwards className to the animated wrapper", () => {
    installMatchMediaStub(false)
    render(
      <FadeIn className="custom-class">
        <p>con clase</p>
      </FadeIn>
    )
    const wrapper = screen.getByText("con clase").parentElement as HTMLElement
    expect(wrapper.className).toContain("custom-class")
  })
})
