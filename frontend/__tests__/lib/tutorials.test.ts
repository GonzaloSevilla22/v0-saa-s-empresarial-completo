/**
 * TDD tests for the tutorial catalog (frontend/lib/tutorials.ts) — the single
 * source of truth for tutorial videos consumed by the landing page and the
 * dashboard's contextual "Ver tutorial" button.
 *
 * Scope 2026-07-29 (PO): the catalog covers 10 tutorials — Onboarding
 * (general, no dashboard route) + 9 modules (Tablero, Ventas, Compras,
 * Productos, Stock, Gastos, Clientes, Consejos IA, Simulador de Precios).
 *
 * Estado 2026-07-29 (PO entregó los videos): los 10 `youtubeVideoId` están
 * cargados — la feature pasa a ser visible. El comportamiento con `null`
 * (tutorial pendiente) se sigue cubriendo con fixtures, no con el catálogo
 * real.
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

/** Mapeo oficial entregado por el PO (URLs youtu.be/<id>, 2026-07-29). */
const EXPECTED_VIDEO_IDS: Record<Tutorial["moduleKey"], string> = {
  onboarding: "C_SUggjXdkw",
  dashboard: "U6qli8FlMh4",
  ventas: "ozpyvm5BXqE",
  compras: "53aV89Pikdc",
  productos: "c33ZUWjCoHA",
  stock: "QXFTEBCLMZo",
  gastos: "5OV88rvz-MU",
  clientes: "Ak9as52T3c8",
  insights: "AmKOe8w3f90",
  simulador: "FL6sRkKp3xQ",
}

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

  // ── Estado post-entrega del PO: los 10 IDs cargados, mapeo exacto ──────
  it("every entry carries exactly the youtubeVideoId the PO delivered for that module (no crossed IDs)", () => {
    for (const t of TUTORIALS) {
      expect(t.youtubeVideoId).toBe(EXPECTED_VIDEO_IDS[t.moduleKey])
    }
  })

  it("all 10 youtubeVideoIds are 11-character YouTube ids and unique", () => {
    const ids = TUTORIALS.map((t) => t.youtubeVideoId)
    ids.forEach((id) => {
      expect(id).not.toBeNull()
      expect(id).toHaveLength(11)
      expect(id).toMatch(/^[A-Za-z0-9_-]{11}$/)
    })
    expect(new Set(ids).size).toBe(10)
  })
})

describe("hasTutorialVideo", () => {
  // ── RED → GREEN: happy path (fixture) ─────────────────────────────────
  it("returns true when youtubeVideoId is a non-null string", () => {
    expect(hasTutorialVideo({ youtubeVideoId: "abc123XYZ99" } as Tutorial)).toBe(true)
  })

  // ── TRIANGULATE: pending video is not available (fixture keeps the null
  //    contract covered even though the real catalog no longer has nulls) ──
  it("returns false when youtubeVideoId is null (video not yet uploaded)", () => {
    expect(hasTutorialVideo({ youtubeVideoId: null } as Tutorial)).toBe(false)
  })
})

describe("getAvailableTutorials", () => {
  // ── RED → GREEN: with the delivered catalog, all 10 are available ─────
  it("returns the full catalog of 10 now that every youtubeVideoId is loaded", () => {
    const available = getAvailableTutorials()
    expect(available).toHaveLength(10)
    expect(available.map((t) => t.moduleKey)).toEqual(TUTORIALS.map((t) => t.moduleKey))
  })

  // ── TRIANGULATE: the availability invariant holds entry by entry ───────
  it("returns only tutorials whose youtubeVideoId is not null", () => {
    const available = getAvailableTutorials()
    expect(available.length).toBeGreaterThan(0)
    expect(available.every((t) => t.youtubeVideoId !== null)).toBe(true)
  })
})

describe("getTutorialByPathname", () => {
  // ── RED → GREEN: known pathname resolves to its entry, now with video ──
  it("returns the matching entry — with its delivered video id — for a catalog pathname", () => {
    const found = getTutorialByPathname("/ventas")
    expect(found).toBeDefined()
    expect(found?.moduleKey).toBe("ventas")
    expect(found?.youtubeVideoId).toBe("ozpyvm5BXqE")
    expect(found && hasTutorialVideo(found)).toBe(true)
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
})
