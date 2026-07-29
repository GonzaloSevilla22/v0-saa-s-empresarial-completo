/**
 * Tests for `SceneErrorBoundary` (components/three/SceneErrorBoundary.tsx),
 * spec `immersive-3d-surfaces` Requirement "Resiliencia ante fallo de escena":
 * a 3D scene that throws during render SHALL degrade to its static poster,
 * never leave the surface blank, and never propagate the error to the rest
 * of the app.
 *
 * Cycle: RED (component doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen } from "@testing-library/react"
import { SceneErrorBoundary } from "@/components/three/SceneErrorBoundary"

function Bomb(): never {
  throw new Error("simulated scene render failure")
}

describe("SceneErrorBoundary", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  // ── RED/GREEN: happy path — no error, renders children ──────────────────
  it("renders its children when there is no error", () => {
    render(
      <SceneErrorBoundary fallback={<p>poster</p>}>
        <p>escena 3d</p>
      </SceneErrorBoundary>,
    )
    expect(screen.getByText("escena 3d")).toBeInTheDocument()
    expect(screen.queryByText("poster")).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: a render failure degrades to the fallback poster ───────
  it("degrades to the fallback poster when a child throws during render", () => {
    // React logs the caught error to console.error — expected noise, silence it.
    vi.spyOn(console, "error").mockImplementation(() => {})

    render(
      <SceneErrorBoundary fallback={<p>poster</p>}>
        <Bomb />
      </SceneErrorBoundary>,
    )

    expect(screen.getByText("poster")).toBeInTheDocument()
    expect(screen.queryByText("escena 3d")).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: onError is called with the caught error, doesn't propagate ──
  it("calls onError with the caught error instead of letting it propagate", () => {
    vi.spyOn(console, "error").mockImplementation(() => {})
    const onError = vi.fn()

    expect(() =>
      render(
        <SceneErrorBoundary fallback={<p>poster</p>} onError={onError}>
          <Bomb />
        </SceneErrorBoundary>,
      ),
    ).not.toThrow()

    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError.mock.calls[0][0]).toBeInstanceOf(Error)
  })
})
