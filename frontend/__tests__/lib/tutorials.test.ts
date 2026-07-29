/**
 * TDD tests for the tutorial catalog (frontend/lib/tutorials.ts) — the single
 * source of truth for tutorial videos consumed by the landing page and the
 * dashboard's contextual "Ver tutorial" button.
 *
 * Scope 2026-07-29 (PO): the catalog covers 10 tutorials — Onboarding
 * (general, no dashboard route) + 9 modules (Tablero, Ventas, Compras,
 * Productos, Stock, Gastos, Clientes, Consejos IA, Simulador de Precios).
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
  it("has exactly the 10 entries in landing order: onboarding first, then the 9 modules", () => {
    const moduleKeys = TUTORIALS.map((t) => t.moduleKey)
    expect(moduleKeys).toEqual([
      "onboarding",
      "dashboard",
      "ventas",
      "compras",
      "productos",
      "stock",
      "gastos",
      "clientes",
      "insights",
      "simulador",
    ])
  })

  it("every entry has the required shape with correct types (pathname is string or null)", () => {
    TUTORIALS.forEach((t: Tutorial) => {
      expect(typeof t.moduleKey).toBe("string")
      expect(typeof t.title).toBe("string")
      expect(typeof t.description).toBe("string")
      expect(typeof t.durationLabel).toBe("string")
      expect(t.pathname === null || typeof t.pathname === "string").toBe(true)
      expect(t.youtubeVideoId === null || typeof t.youtubeVideoId === "string").toBe(true)
    })
  })

  it("only onboarding has pathname null (general video, not tied to a dashboard route)", () => {
    const withoutRoute = TUTORIALS.filter((t) => t.pathname === null).map((t) => t.moduleKey)
    expect(withoutRoute).toEqual(["onboarding"])
  })

  it("module entries map to their canonical dashboard routes (PAGE_NAMES keys)", () => {
    const byKey = new Map(TUTORIALS.map((t) => [t.moduleKey, t.pathname]))
    expect(byKey.get("dashboard")).toBe("/dashboard")
    expect(byKey.get("clientes")).toBe("/clientes")
    expect(byKey.get("insights")).toBe("/insights")
    expect(byKey.get("simulador")).toBe("/simulador")
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

  // ── TRIANGULATE: the 4 routes added in the 10-tutorial extension resolve too ──
  it("resolves the new routes /dashboard, /clientes, /insights and /simulador", () => {
    expect(getTutorialByPathname("/dashboard")?.moduleKey).toBe("dashboard")
    expect(getTutorialByPathname("/clientes")?.moduleKey).toBe("clientes")
    expect(getTutorialByPathname("/insights")?.moduleKey).toBe("insights")
    expect(getTutorialByPathname("/simulador")?.moduleKey).toBe("simulador")
  })

  // ── TRIANGULATE: unknown pathname → undefined ──────────────────────────
  it("returns undefined for a pathname not present in the catalog", () => {
    expect(getTutorialByPathname("/no-existe")).toBeUndefined()
  })

  // ── TRIANGULATE: onboarding (pathname null) is never reachable by route lookup ──
  it("never returns the onboarding entry for any route (its pathname is null)", () => {
    const routes = ["/dashboard", "/ventas", "/compras", "/productos", "/stock", "/gastos", "/clientes", "/insights", "/simulador", "/onboarding", "/"]
    for (const route of routes) {
      expect(getTutorialByPathname(route)?.moduleKey).not.toBe("onboarding")
    }
  })

  // ── TRIANGULATE: pathname exists but video is null → still returns the raw entry ──
  it("returns the entry even when its youtubeVideoId is null (consumer decides via hasTutorialVideo)", () => {
    const found = getTutorialByPathname("/stock")
    expect(found).toBeDefined()
    expect(found?.youtubeVideoId).toBeNull()
  })
})
