/**
 * Tests for the reactive `useCapabilityGate` hook (hooks/three/useCapabilityGate.ts),
 * the browser-reading half of the 3D capability gate (design.md D5 / spec
 * `immersive-3d-surfaces`). `lib/three/capabilityGate.test.ts` covers the pure
 * decision logic exhaustively; this suite only covers the hook's own
 * responsibilities: SSR-safe initial value, resolving after mount, and
 * reacting to a live reduced-motion toggle.
 *
 * Cycle: RED (hook doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect, afterEach, vi } from "vitest"
import { renderHook, act, waitFor } from "@testing-library/react"
import { useCapabilityGate } from "@/hooks/three/useCapabilityGate"

function installMatchMediaStub(reducedMotion: boolean, pointerCoarse = false) {
  const listeners: Array<(e: MediaQueryListEvent) => void> = []
  // Mutable so a later `readCapabilitySignals()` call (triggered by the
  // "change" listener) sees the updated value — not just the synthetic event.
  const state = { reducedMotion }

  window.matchMedia = (query: string): MediaQueryList => {
    const isReducedMotionQuery = query.includes("prefers-reduced-motion")
    return {
      get matches() {
        return isReducedMotionQuery ? state.reducedMotion : pointerCoarse
      },
      media: query,
      onchange: null,
      addEventListener: (_event: string, handler: (e: MediaQueryListEvent) => void) => {
        if (isReducedMotionQuery) listeners.push(handler)
      },
      removeEventListener: (_event: string, handler: (e: MediaQueryListEvent) => void) => {
        const idx = listeners.indexOf(handler)
        if (idx !== -1) listeners.splice(idx, 1)
      },
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    } as unknown as MediaQueryList
  }

  return {
    fireReducedMotionChange(matches: boolean) {
      state.reducedMotion = matches
      listeners.forEach((handler) => handler({ matches } as MediaQueryListEvent))
    },
  }
}

function installWebGLStub(hasWebGL: boolean) {
  vi.spyOn(HTMLCanvasElement.prototype, "getContext").mockImplementation(((
    contextId: string,
  ) => {
    if (!hasWebGL) return null
    if (contextId === "webgl2" || contextId === "webgl") return {}
    return null
  }) as typeof HTMLCanvasElement.prototype.getContext)
}

describe("useCapabilityGate", () => {
  afterEach(() => {
    // @ts-expect-error -- cleanup jsdom global between tests
    delete window.matchMedia
    vi.restoreAllMocks()
  })

  // ── RED/GREEN: SSR-safe initial value — never qualifies before mount ────
  it("never qualifies on the very first render (SSR-safe default, before the effect resolves)", () => {
    installMatchMediaStub(false)
    installWebGLStub(true)
    const { result } = renderHook(() => useCapabilityGate())
    expect(result.current.qualifies).toBe(false)
  })

  // ── GREEN: resolves to "qualifies" after mount on a capable desktop ─────
  it("resolves to qualifies=true after mount on a capable desktop", async () => {
    installMatchMediaStub(false, false)
    installWebGLStub(true)
    Object.defineProperty(window.navigator, "hardwareConcurrency", { value: 8, configurable: true })

    const { result } = renderHook(() => useCapabilityGate())
    await waitFor(() => expect(result.current.qualifies).toBe(true))
    expect(result.current.reason).toBe("qualifies")
  })

  // ── TRIANGULATE: resolves to qualifies=false when there is no WebGL ─────
  it("resolves to qualifies=false with reason no-webgl when WebGL is unavailable", async () => {
    installMatchMediaStub(false, false)
    installWebGLStub(false)
    Object.defineProperty(window.navigator, "hardwareConcurrency", { value: 8, configurable: true })

    const { result } = renderHook(() => useCapabilityGate())
    await waitFor(() => expect(result.current.reason).toBe("no-webgl"))
    expect(result.current.qualifies).toBe(false)
  })

  // ── TRIANGULATE: reacts to a live reduced-motion toggle after resolving ─
  it("reacts to a live prefers-reduced-motion toggle after the initial resolve", async () => {
    const stub = installMatchMediaStub(false, false)
    installWebGLStub(true)
    Object.defineProperty(window.navigator, "hardwareConcurrency", { value: 8, configurable: true })

    const { result } = renderHook(() => useCapabilityGate())
    await waitFor(() => expect(result.current.qualifies).toBe(true))

    act(() => {
      stub.fireReducedMotionChange(true)
    })

    await waitFor(() => expect(result.current.reason).toBe("reduced-motion"))
    expect(result.current.qualifies).toBe(false)
  })
})
