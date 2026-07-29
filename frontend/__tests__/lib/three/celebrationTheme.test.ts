/**
 * Tests for `getCelebrationColors` (lib/three/celebrationTheme.ts) — the pure
 * variant+theme → color-palette mapping consumed by
 * `components/three/CelebrationScene.tsx` (tasks 3.5/3.6). Same "pure logic
 * separated from the WebGL render" pattern as `heroSceneTheme.ts`.
 *
 * Cycle: RED (module doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { getCelebrationColors } from "@/lib/three/celebrationTheme"

describe("getCelebrationColors", () => {
  // ── RED/GREEN: "sale" variant returns a non-empty palette ───────────────
  it("returns a non-empty hex color palette for the sale variant", () => {
    const colors = getCelebrationColors("sale", "light")
    expect(colors.length).toBeGreaterThan(0)
    colors.forEach((c) => expect(c).toMatch(/^#[0-9a-f]{6}$/i))
  })

  // ── TRIANGULATE: "goal" variant is a DIFFERENT palette (distinguishable) ──
  it("returns a different palette for the goal variant than the sale variant", () => {
    const sale = getCelebrationColors("sale", "light")
    const goal = getCelebrationColors("goal", "light")
    expect(goal).not.toEqual(sale)
  })

  // ── TRIANGULATE: theme changes the palette too (light vs dark) ──────────
  it("returns a different palette for dark theme than light theme (same variant)", () => {
    const light = getCelebrationColors("sale", "light")
    const dark = getCelebrationColors("sale", "dark")
    expect(dark).not.toEqual(light)
  })
})
