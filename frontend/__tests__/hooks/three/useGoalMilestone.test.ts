/**
 * Tests for `useGoalMilestone` (hooks/three/useGoalMilestone.ts) — wires
 * `findCrossedMilestone` (lib/three/goalMilestone.ts) to a component's
 * already-fetched KPI value.
 *
 * Key policy (why this needs its own hook, not just the pure function): the
 * FIRST real value received after loading finishes becomes the baseline and
 * is NEVER itself reported as a crossing — otherwise every page load/reload
 * where today's sales already exceed a threshold would "celebrate" a
 * milestone that was actually reached earlier (stale, not a live moment).
 * Only a later increase past a threshold, relative to that baseline, fires.
 *
 * Cycle: RED (hook doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { renderHook } from "@testing-library/react"
import { useGoalMilestone } from "@/hooks/three/useGoalMilestone"

const THRESHOLDS = [50_000, 100_000] as const

describe("useGoalMilestone", () => {
  // ── RED/GREEN: while loading, never reports anything ────────────────────
  it("returns null while the KPI is still loading, even if the value already exceeds a threshold", () => {
    const { result } = renderHook(() => useGoalMilestone(60_000, THRESHOLDS, true))
    expect(result.current).toBeNull()
  })

  // ── GREEN: the FIRST resolved value establishes a baseline — no celebration yet ──
  it("does not report a crossing for the first value received once loading finishes, even above a threshold", () => {
    const { result, rerender } = renderHook(
      ({ value, isLoading }) => useGoalMilestone(value, THRESHOLDS, isLoading),
      { initialProps: { value: 0, isLoading: true } },
    )
    expect(result.current).toBeNull()

    rerender({ value: 60_000, isLoading: false }) // loading finishes with an already-high value
    expect(result.current).toBeNull()
  })

  // ── TRIANGULATE: a LATER increase past a threshold, after the baseline, DOES fire ──
  it("reports a crossing when the value increases past a threshold after the baseline is established", () => {
    const { result, rerender } = renderHook(
      ({ value, isLoading }) => useGoalMilestone(value, THRESHOLDS, isLoading),
      { initialProps: { value: 20_000, isLoading: false } }, // baseline established at 20k
    )
    expect(result.current).toBeNull()

    rerender({ value: 60_000, isLoading: false }) // live increase crosses 50k
    expect(result.current).toBe(50_000)
  })

  // ── TRIANGULATE: a decrease (e.g. branch filter switch) never reports a crossing ──
  it("does not report a crossing when the value decreases", () => {
    const { result, rerender } = renderHook(
      ({ value, isLoading }) => useGoalMilestone(value, THRESHOLDS, isLoading),
      { initialProps: { value: 120_000, isLoading: false } },
    )
    rerender({ value: 10_000, isLoading: false })
    expect(result.current).toBeNull()
  })
})
