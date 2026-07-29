/**
 * Tests for the SSR-safe usePrefersReducedMotion hook (hooks/ui/usePrefersReducedMotion.ts),
 * wired into components/motion/* to degrade animations per
 * `prefers-reduced-motion: reduce` (spec `visual-design-system`).
 *
 * jsdom doesn't implement matchMedia, so each test installs a minimal
 * MediaQueryList stub (same pattern as __tests__/components/ResponsiveModal.test.tsx).
 *
 * Cycle: RED (hook module doesn't exist yet) → GREEN → TRIANGULATE
 * (no-preference vs reduce vs reactive change) → REFACTOR.
 */

import { describe, it, expect, afterEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { usePrefersReducedMotion } from "@/hooks/ui/usePrefersReducedMotion"

function installMatchMediaStub(initialMatches: boolean) {
  const listeners: Array<(e: MediaQueryListEvent) => void> = []
  const mql = {
    matches: initialMatches,
    media: "(prefers-reduced-motion: reduce)",
    onchange: null,
    addEventListener: (_event: string, handler: (e: MediaQueryListEvent) => void) => {
      listeners.push(handler)
    },
    removeEventListener: (_event: string, handler: (e: MediaQueryListEvent) => void) => {
      const idx = listeners.indexOf(handler)
      if (idx !== -1) listeners.splice(idx, 1)
    },
    addListener: () => {},
    removeListener: () => {},
    dispatchEvent: () => false,
  } as unknown as MediaQueryList

  window.matchMedia = () => mql

  return {
    fireChange(matches: boolean) {
      ;(mql as unknown as { matches: boolean }).matches = matches
      listeners.forEach((handler) => handler({ matches } as MediaQueryListEvent))
    },
  }
}

describe("usePrefersReducedMotion", () => {
  afterEach(() => {
    // @ts-expect-error -- cleanup jsdom global between tests
    delete window.matchMedia
  })

  // ── RED/GREEN: happy path — user has no motion preference ──
  it("returns false when the OS does not request reduced motion", () => {
    installMatchMediaStub(false)
    const { result } = renderHook(() => usePrefersReducedMotion())
    expect(result.current).toBe(false)
  })

  // ── TRIANGULATE: edge case — reduced motion requested ──
  it("returns true when the OS requests prefers-reduced-motion: reduce", () => {
    installMatchMediaStub(true)
    const { result } = renderHook(() => usePrefersReducedMotion())
    expect(result.current).toBe(true)
  })

  // ── TRIANGULATE: reactive — user toggles the OS setting mid-session ──
  it("reacts to a live change of the media query (no reload required)", () => {
    const stub = installMatchMediaStub(false)
    const { result } = renderHook(() => usePrefersReducedMotion())
    expect(result.current).toBe(false)

    act(() => {
      stub.fireChange(true)
    })

    expect(result.current).toBe(true)
  })
})
