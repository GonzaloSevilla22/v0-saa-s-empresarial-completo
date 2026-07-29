/**
 * Tests for `GatedSceneMount` (components/three/GatedSceneMount.tsx).
 *
 * Found via browser E2E on the landing pilot (task 2.10): `HeroSceneMount`
 * unconditionally rendered its `next/dynamic({ssr:false})`-wrapped scene, and
 * `next/dynamic` starts fetching the chunk as soon as that component RENDERS
 * — regardless of what it internally decides to show. Confirmed empirically:
 * the R3F/three chunk (~233KB gz) downloaded on the landing route even while
 * the capability gate was disqualifying the device (verified via network
 * inspection in the Browser pane). `Lazy3DCanvas`'s own gate+viewport check
 * only decided Canvas-vs-poster AFTER the chunk had already downloaded — too
 * late to matter for spec `immersive-3d-surfaces`'s Save-Data/mobile
 * Scenarios, whose whole point is to avoid the download.
 *
 * `GatedSceneMount` is the fix: gate (capability) AND viewport BEFORE ever
 * rendering the dynamically-imported component, so a disqualified or
 * below-the-fold visitor never triggers the fetch at all.
 *
 * Cycle: RED (component doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import type { CapabilityGateResult } from "@/lib/three/capabilityGate"
import { GatedSceneMount } from "@/components/three/GatedSceneMount"

const { mockUseCapabilityGate } = vi.hoisted(() => ({
  mockUseCapabilityGate: vi.fn<() => CapabilityGateResult>(),
}))
vi.mock("@/hooks/three/useCapabilityGate", () => ({
  useCapabilityGate: () => mockUseCapabilityGate(),
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

describe("GatedSceneMount", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    mockUseCapabilityGate.mockReset()
  })

  // ── The core regression: disqualified device NEVER triggers the importer ──
  it("never calls the importer when the capability gate disqualifies the device", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: false, reason: "no-webgl" })
    const importer = vi.fn(() => Promise.resolve({ default: () => <div data-testid="scene" /> }))
    installIntersectionObserverStub()

    render(<GatedSceneMount importer={importer} poster={<p>poster</p>} />)

    expect(importer).not.toHaveBeenCalled()
    expect(screen.getByText("poster")).toBeInTheDocument()
  })

  // ── Qualified but not yet in viewport: also never triggers the importer ──
  it("never calls the importer while qualified but not yet in viewport", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    const importer = vi.fn(() => Promise.resolve({ default: () => <div data-testid="scene" /> }))
    installIntersectionObserverStub()

    render(<GatedSceneMount importer={importer} poster={<p>poster</p>} />)

    expect(importer).not.toHaveBeenCalled()
    expect(screen.getByText("poster")).toBeInTheDocument()
  })

  // ── Qualified AND in viewport: triggers the importer, renders its result ──
  it("calls the importer and renders the resolved scene once qualified AND in viewport", async () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    const importer = vi.fn(() => Promise.resolve({ default: () => <div data-testid="scene" /> }))
    const stub = installIntersectionObserverStub()

    render(<GatedSceneMount importer={importer} poster={<p>poster</p>} />)

    act(() => stub.fireIntersect(true))

    expect(importer).toHaveBeenCalledTimes(1)
    expect(await screen.findByTestId("scene")).toBeInTheDocument()
    expect(screen.queryByText("poster")).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: leaving the viewport unmounts back to poster, without a duplicate fetch ──
  it("falls back to the poster when leaving the viewport again, without calling the importer twice", async () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    const importer = vi.fn(() => Promise.resolve({ default: () => <div data-testid="scene" /> }))
    const stub = installIntersectionObserverStub()

    render(<GatedSceneMount importer={importer} poster={<p>poster</p>} />)
    act(() => stub.fireIntersect(true))
    await screen.findByTestId("scene")

    act(() => stub.fireIntersect(false))

    expect(screen.getByText("poster")).toBeInTheDocument()
    expect(importer).toHaveBeenCalledTimes(1)
  })
})
