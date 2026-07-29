/**
 * Tests for `findCrossedMilestone` (lib/three/goalMilestone.ts) — the pure
 * detector behind the "meta alcanzada" celebration (task 3.6). Purely
 * presentational: given a previous/current numeric KPI reading and a list of
 * round-number thresholds, returns the highest threshold newly crossed (or
 * `null`). Does not read/write any KPI itself — the dashboard passes in
 * values it already fetched via its existing (untouched) data flow.
 *
 * Cycle: RED (module doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { findCrossedMilestone } from "@/lib/three/goalMilestone"

const THRESHOLDS = [50_000, 100_000, 250_000] as const

describe("findCrossedMilestone", () => {
  // ── RED/GREEN: crosses exactly one threshold ─────────────────────────────
  it("returns the threshold when the value crosses it", () => {
    expect(findCrossedMilestone(40_000, 60_000, THRESHOLDS)).toBe(50_000)
  })

  // ── TRIANGULATE: no crossing → null ──────────────────────────────────────
  it("returns null when no threshold is crossed", () => {
    expect(findCrossedMilestone(10_000, 20_000, THRESHOLDS)).toBeNull()
  })

  // ── TRIANGULATE: jumps over multiple thresholds at once → the HIGHEST one ──
  it("returns the highest threshold when a jump crosses several at once", () => {
    expect(findCrossedMilestone(40_000, 300_000, THRESHOLDS)).toBe(250_000)
  })

  // ── TRIANGULATE: value decreasing never counts as a crossing ────────────
  it("never reports a crossing when the value decreases", () => {
    expect(findCrossedMilestone(120_000, 80_000, THRESHOLDS)).toBeNull()
  })

  // ── TRIANGULATE: staying exactly at an already-crossed threshold → no re-trigger ──
  it("does not re-report a threshold the previous value already met", () => {
    expect(findCrossedMilestone(50_000, 60_000, THRESHOLDS)).toBeNull()
  })
})
