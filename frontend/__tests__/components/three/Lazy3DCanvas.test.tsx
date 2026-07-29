/**
 * Tests for `Lazy3DCanvas` (components/three/Lazy3DCanvas.tsx) — spec
 * `immersive-3d-surfaces`, Requirements "Carga fuera del critical path" and
 * "Gate de capacidad con fallback estático": consumes the gate, mounts the
 * `<Canvas>` only via IntersectionObserver, unmounts it (pausing the render
 * loop) when leaving the viewport, and always keeps the container
 * `aria-hidden`.
 *
 * `@react-three/fiber`'s real `<Canvas>` needs an actual WebGL context, which
 * jsdom cannot provide — it's mocked here so these tests exercise
 * Lazy3DCanvas's own gating/observer logic, not R3F/WebGL internals.
 * `useCapabilityGate` is mocked too so each test controls the gate result
 * directly instead of faking browser signals (already covered exhaustively
 * by capabilityGate.test.ts / useCapabilityGate.test.ts).
 *
 * Cycle: RED (component doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import type { CapabilityGateResult } from "@/lib/three/capabilityGate"
import { Lazy3DCanvas } from "@/components/three/Lazy3DCanvas"

// `vi.mock` factories are hoisted above imports/consts, so any outer-scope
// variable they close over must go through `vi.hoisted` — otherwise it's
// accessed before its `const` initializer runs ("Cannot access before
// initialization").
const { mockUseCapabilityGate } = vi.hoisted(() => ({
  mockUseCapabilityGate: vi.fn<() => CapabilityGateResult>(),
}))

vi.mock("@/hooks/three/useCapabilityGate", () => ({
  useCapabilityGate: () => mockUseCapabilityGate(),
}))

vi.mock("@react-three/fiber", () => ({
  Canvas: (props: { frameloop?: string; children?: React.ReactNode }) => (
    <div data-testid="r3f-canvas" data-frameloop={props.frameloop}>
      {props.children}
    </div>
  ),
}))

function installIntersectionObserverStub() {
  let currentCallback: IntersectionObserverCallback | null = null

  class StubIntersectionObserver {
    constructor(callback: IntersectionObserverCallback) {
      currentCallback = callback
    }
    observe() {}
    unobserve() {}
    disconnect() {}
    takeRecords(): IntersectionObserverEntry[] {
      return []
    }
  }

  window.IntersectionObserver = StubIntersectionObserver as unknown as typeof IntersectionObserver

  return {
    fireIntersect(isIntersecting: boolean) {
      currentCallback?.(
        [{ isIntersecting } as IntersectionObserverEntry],
        {} as IntersectionObserver,
      )
    },
  }
}

describe("Lazy3DCanvas", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    mockUseCapabilityGate.mockReset()
  })

  // ── Gate de capacidad: disqualified → poster, sin observer ──────────────
  it("renders only the poster when the capability gate disqualifies the device", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: false, reason: "no-webgl" })

    render(
      <Lazy3DCanvas poster={<p>poster</p>}>
        <div data-testid="scene-content" />
      </Lazy3DCanvas>,
    )

    expect(screen.getByText("poster")).toBeInTheDocument()
    expect(screen.queryByTestId("r3f-canvas")).not.toBeInTheDocument()
  })

  // ── RED/GREEN: qualified but not yet in viewport → still poster ─────────
  it("renders the poster (not the Canvas) while qualified but not yet in viewport", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    installIntersectionObserverStub()

    render(
      <Lazy3DCanvas poster={<p>poster</p>}>
        <div data-testid="scene-content" />
      </Lazy3DCanvas>,
    )

    expect(screen.getByText("poster")).toBeInTheDocument()
    expect(screen.queryByTestId("r3f-canvas")).not.toBeInTheDocument()
  })

  // ── Montaje por viewport: qualified + in view → mounts <Canvas frameloop=demand> ──
  it("mounts the Canvas with frameloop=demand once qualified AND in viewport", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    const stub = installIntersectionObserverStub()

    render(
      <Lazy3DCanvas poster={<p>poster</p>}>
        <div data-testid="scene-content" />
      </Lazy3DCanvas>,
    )

    act(() => stub.fireIntersect(true))

    expect(screen.getByTestId("r3f-canvas")).toHaveAttribute("data-frameloop", "demand")
    expect(screen.getByTestId("scene-content")).toBeInTheDocument()
    expect(screen.queryByText("poster")).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: salir del viewport desmonta el Canvas (pausa el loop) ──
  it("unmounts the Canvas (falls back to poster) when leaving the viewport", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    const stub = installIntersectionObserverStub()

    render(
      <Lazy3DCanvas poster={<p>poster</p>}>
        <div data-testid="scene-content" />
      </Lazy3DCanvas>,
    )

    act(() => stub.fireIntersect(true))
    expect(screen.getByTestId("r3f-canvas")).toBeInTheDocument()

    act(() => stub.fireIntersect(false))
    expect(screen.queryByTestId("r3f-canvas")).not.toBeInTheDocument()
    expect(screen.getByText("poster")).toBeInTheDocument()
  })

  // ── Accesibilidad: el contenedor SIEMPRE es aria-hidden ──────────────────
  it("keeps the container aria-hidden in every state", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: false, reason: "reduced-motion" })

    const { container } = render(
      <Lazy3DCanvas poster={<p>poster</p>}>
        <div data-testid="scene-content" />
      </Lazy3DCanvas>,
    )

    expect(container.firstElementChild).toHaveAttribute("aria-hidden", "true")
  })
})
