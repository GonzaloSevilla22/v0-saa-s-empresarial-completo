/**
 * TDD tests for the tutorial catalog (frontend/lib/tutorials.ts) — the single
 * source of truth for tutorial videos consumed by the landing page and the
 * dashboard's contextual "Ver tutorial" button.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect } from "vitest"
import {
  TUTORIALS,
  hasTutorialVideo,
  getAvailableTutorials,
  getTutorialByPathname,
  type Tutorial,
} from "@/lib/tutorials"

describe("TUTORIALS catalog", () => {
  it("has exactly one entry per operational module (ventas, compras, productos, stock, gastos)", () => {
    const moduleKeys = TUTORIALS.map((t) => t.moduleKey).sort()
    expect(moduleKeys).toEqual(["compras", "gastos", "productos", "stock", "ventas"])
  })

  it("every entry has the required shape with correct types", () => {
    TUTORIALS.forEach((t: Tutorial) => {
      expect(typeof t.moduleKey).toBe("string")
      expect(typeof t.title).toBe("string")
      expect(typeof t.description).toBe("string")
      expect(typeof t.durationLabel).toBe("string")
      expect(typeof t.pathname).toBe("string")
      expect(t.youtubeVideoId === null || typeof t.youtubeVideoId === "string").toBe(true)
    })
  })
})

describe("hasTutorialVideo", () => {
  // ── RED → GREEN: happy path ───────────────────────────────────────────
  it("returns true when youtubeVideoId is a non-null string", () => {
    expect(hasTutorialVideo({ youtubeVideoId: "abc123XYZ" } as Tutorial)).toBe(true)
  })

  // ── TRIANGULATE: pending video is not available ───────────────────────
  it("returns false when youtubeVideoId is null (video not yet uploaded)", () => {
    expect(hasTutorialVideo({ youtubeVideoId: null } as Tutorial)).toBe(false)
  })
})

describe("getAvailableTutorials", () => {
  // ── RED → GREEN: today, no real IDs exist yet → catalog is all-null ──
  it("returns only tutorials whose youtubeVideoId is not null", () => {
    const available = getAvailableTutorials()
    expect(available.every((t) => t.youtubeVideoId !== null)).toBe(true)
  })

  // ── TRIANGULATE: with the current all-placeholder catalog, the result is empty ──
  it("returns an empty array today, since every catalog entry is still a null placeholder", () => {
    expect(getAvailableTutorials()).toEqual([])
  })
})

describe("getTutorialByPathname", () => {
  // ── RED → GREEN: known pathname resolves to its entry ─────────────────
  it("returns the matching entry for a pathname present in the catalog", () => {
    const found = getTutorialByPathname("/ventas")
    expect(found).toBeDefined()
    expect(found?.moduleKey).toBe("ventas")
  })

  // ── TRIANGULATE: unknown pathname → undefined ──────────────────────────
  it("returns undefined for a pathname not present in the catalog", () => {
    expect(getTutorialByPathname("/no-existe")).toBeUndefined()
  })

  // ── TRIANGULATE: pathname exists but video is null → still returns the raw entry ──
  it("returns the entry even when its youtubeVideoId is null (consumer decides via hasTutorialVideo)", () => {
    const found = getTutorialByPathname("/stock")
    expect(found).toBeDefined()
    expect(found?.youtubeVideoId).toBeNull()
  })
})
