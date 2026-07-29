/**
 * Tests for `Celebration3D` (components/three/Celebration3D.tsx) — the
 * on-demand, efímero 3D burst for "venta cerrada" (task 3.5) / "meta
 * alcanzada" (task 3.6). Spec `immersive-3d-surfaces` scoped to this
 * surface: mounted on-demand via `show`, auto-unmounted, respects
 * reduced-motion (via the capability gate — "sin burst", not a poster —
 * an ephemeral effect has no meaningful static substitute), and NEVER
 * blocks the caller's flow (POS checkout / dashboard) — it's a
 * `pointer-events-none` overlay, never a modal.
 *
 * `useCapabilityGate` is mocked (already covered exhaustively elsewhere);
 * the heavy `CelebrationCanvas` (R3F) is mocked too — this suite only
 * covers Celebration3D's own show/gate/timer orchestration.
 *
 * Cycle: RED (component doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import type { CapabilityGateResult } from "@/lib/three/capabilityGate"

const { mockUseCapabilityGate } = vi.hoisted(() => ({
  mockUseCapabilityGate: vi.fn<() => CapabilityGateResult>(),
}))
vi.mock("@/hooks/three/useCapabilityGate", () => ({
  useCapabilityGate: () => mockUseCapabilityGate(),
}))

vi.mock("@/components/three/CelebrationCanvas", () => ({
  default: ({ variant }: { variant: string }) => <div data-testid="celebration-canvas">{variant}</div>,
}))

const { Celebration3D } = await import("@/components/three/Celebration3D")

describe("Celebration3D", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    mockUseCapabilityGate.mockReset()
  })

  // ── RED/GREEN: show=false renders nothing ────────────────────────────────
  it("renders nothing when show is false", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    render(<Celebration3D show={false} />)
    expect(screen.queryByTestId("celebration-canvas")).not.toBeInTheDocument()
  })

  // ── GREEN: show=true + qualified device → mounts the burst ──────────────
  it("mounts the celebration burst when show is true and the device qualifies", async () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    render(<Celebration3D show={true} variant="sale" />)
    // `loadScene`'s real next/dynamic resolves asynchronously even with the module mocked.
    expect(await screen.findByTestId("celebration-canvas")).toHaveTextContent("sale")
  })

  // ── TRIANGULATE: reduced-motion (via the gate) → NO burst at all ────────
  it("renders no burst when the capability gate disqualifies (e.g. reduced-motion)", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: false, reason: "reduced-motion" })
    render(<Celebration3D show={true} />)
    expect(screen.queryByTestId("celebration-canvas")).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: auto-unmounts after its duration, without external action ──
  // Real timers + a short duration (avoids the known fake-timers/RTL `waitFor`
  // polling deadlock — `waitFor` polls via `setInterval`, which fake timers
  // would also hijack, requiring manual `advanceTimersByTime` pairing that's
  // not worth the complexity here).
  it("auto-unmounts itself after the celebration duration elapses", async () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    render(<Celebration3D show={true} durationMs={30} />)
    expect(await screen.findByTestId("celebration-canvas")).toBeInTheDocument()

    await waitFor(() => expect(screen.queryByTestId("celebration-canvas")).not.toBeInTheDocument())
  })

  // ── TRIANGULATE: never blocks — the overlay is pointer-events-none and aria-hidden ──
  it("renders a pointer-events-none, aria-hidden overlay (never blocks the caller's flow)", () => {
    mockUseCapabilityGate.mockReturnValue({ qualifies: true, reason: "qualifies" })
    const { container } = render(<Celebration3D show={true} />)
    const overlay = container.firstElementChild as HTMLElement
    expect(overlay).toHaveAttribute("aria-hidden", "true")
    expect(overlay.className).toContain("pointer-events-none")
  })
})
