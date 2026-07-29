/**
 * Tests for `getHeroSceneColors` (lib/three/heroSceneTheme.ts) — the pure
 * theme→material-color mapping consumed by `components/three/scenes/HeroScene.tsx`.
 * Split out from the R3F scene component itself (which needs a real WebGL
 * context and isn't unit-testable in jsdom — verified via browser E2E, task
 * 2.10) so the "reads the active theme and adjusts materials" behavior
 * (design.md D9 / task 3.7) has real unit coverage.
 *
 * Cycle: RED (module doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { getHeroSceneColors } from "@/lib/three/heroSceneTheme"

describe("getHeroSceneColors", () => {
  // ── RED/GREEN: light theme returns a color set ───────────────────────────
  it("returns a primary/accent color set for the light theme", () => {
    const colors = getHeroSceneColors("light")
    expect(colors.primary).toMatch(/^#[0-9a-f]{6}$/i)
    expect(colors.accent).toMatch(/^#[0-9a-f]{6}$/i)
  })

  // ── TRIANGULATE: dark theme returns a DIFFERENT (brighter) color set ────
  it("returns a different, brighter color set for the dark theme (contrast against a dark backdrop)", () => {
    const light = getHeroSceneColors("light")
    const dark = getHeroSceneColors("dark")
    expect(dark.primary).not.toBe(light.primary)
    expect(dark.accent).not.toBe(light.accent)
  })

  // ── TRIANGULATE: emissiveIntensity is higher in dark (needs to "glow" more against black) ──
  it("uses a higher emissiveIntensity in dark theme than in light theme", () => {
    const light = getHeroSceneColors("light")
    const dark = getHeroSceneColors("dark")
    expect(dark.emissiveIntensity).toBeGreaterThan(light.emissiveIntensity)
  })
})
