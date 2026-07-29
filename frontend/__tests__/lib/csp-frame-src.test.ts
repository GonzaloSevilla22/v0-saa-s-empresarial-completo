/**
 * Tests for the Content-Security-Policy built by the middleware
 * (frontend/lib/supabase/middleware.ts → buildContentSecurityPolicy).
 *
 * Fix 2026-07-29 (decisión PO): los tutoriales embeben el iframe de
 * youtube-nocookie.com, así que frame-src debe permitirlo. El resto de la
 * CSP NO se toca: nada de jsdelivr en script-src (el facade propio no usa
 * scripts externos) y youtube-nocookie aparece SOLO en frame-src.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect } from "vitest"
import { buildContentSecurityPolicy } from "@/lib/supabase/middleware"

function getDirective(csp: string, name: string): string | undefined {
  return csp
    .split(";")
    .map((d) => d.trim())
    .find((d) => d.startsWith(`${name} `) || d === name)
}

describe("buildContentSecurityPolicy — frame-src para tutoriales", () => {
  // ── RED → GREEN: frame-src permite youtube-nocookie además de Turnstile ──
  it("allows https://www.youtube-nocookie.com in frame-src (keeping challenges.cloudflare.com)", () => {
    const frameSrc = getDirective(buildContentSecurityPolicy(), "frame-src")
    expect(frameSrc).toBeDefined()
    expect(frameSrc).toContain("https://challenges.cloudflare.com")
    expect(frameSrc).toContain("https://www.youtube-nocookie.com")
  })

  // ── TRIANGULATE: youtube-nocookie SOLO en frame-src, ninguna otra directiva ──
  it("mentions youtube-nocookie ONLY inside frame-src", () => {
    const csp = buildContentSecurityPolicy()
    const occurrences = csp.split("youtube-nocookie.com").length - 1
    expect(occurrences).toBe(1)
    expect(getDirective(csp, "script-src")).not.toContain("youtube-nocookie")
    expect(getDirective(csp, "default-src")).not.toContain("youtube-nocookie")
  })

  // ── TRIANGULATE: el facade propio no requiere scripts externos → sin jsdelivr ──
  it("does NOT allow cdn.jsdelivr.net anywhere (own facade needs no external scripts)", () => {
    expect(buildContentSecurityPolicy()).not.toContain("jsdelivr")
  })

  // ── TRIANGULATE: el resto de las directivas clave sigue intacto ─────────
  it("keeps the untouched directives intact (default-src, frame-ancestors, script-src hosts)", () => {
    const csp = buildContentSecurityPolicy()
    expect(getDirective(csp, "default-src")).toBe("default-src 'self'")
    expect(getDirective(csp, "frame-ancestors")).toBe("frame-ancestors 'none'")
    expect(getDirective(csp, "script-src")).toBe(
      "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://challenges.cloudflare.com"
    )
  })
})
