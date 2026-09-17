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

// auth-hardening-jwt-cookies (D3, task 21.8): `buildContentSecurityPolicy` pasa a
// recibir el nonce de la petición. Estos tests se actualizan en el MISMO commit
// que el cambio de firma; su sujeto (frame-src / worker-src) no se toca.
const NONCE = "n0nc3-de-prueba"

function getDirective(csp: string, name: string): string | undefined {
  return csp
    .split(";")
    .map((d) => d.trim())
    .find((d) => d.startsWith(`${name} `) || d === name)
}

describe("buildContentSecurityPolicy — frame-src para tutoriales", () => {
  // ── RED → GREEN: frame-src permite youtube-nocookie además de Turnstile ──
  it("allows https://www.youtube-nocookie.com in frame-src (keeping challenges.cloudflare.com)", () => {
    const frameSrc = getDirective(buildContentSecurityPolicy(NONCE), "frame-src")
    expect(frameSrc).toBeDefined()
    expect(frameSrc).toContain("https://challenges.cloudflare.com")
    expect(frameSrc).toContain("https://www.youtube-nocookie.com")
  })

  // ── TRIANGULATE: youtube-nocookie SOLO en frame-src, ninguna otra directiva ──
  it("mentions youtube-nocookie ONLY inside frame-src", () => {
    const csp = buildContentSecurityPolicy(NONCE)
    const occurrences = csp.split("youtube-nocookie.com").length - 1
    expect(occurrences).toBe(1)
    expect(getDirective(csp, "script-src")).not.toContain("youtube-nocookie")
    expect(getDirective(csp, "default-src")).not.toContain("youtube-nocookie")
  })

  // ── TRIANGULATE: el facade propio no requiere scripts externos → sin jsdelivr ──
  it("does NOT allow cdn.jsdelivr.net anywhere (own facade needs no external scripts)", () => {
    expect(buildContentSecurityPolicy(NONCE)).not.toContain("jsdelivr")
  })

  // ── TRIANGULATE: el resto de las directivas clave sigue intacto ─────────
  it("keeps the untouched directives intact (default-src, frame-ancestors, script-src hosts)", () => {
    const csp = buildContentSecurityPolicy(NONCE)
    expect(getDirective(csp, "default-src")).toBe("default-src 'self'")
    expect(getDirective(csp, "frame-ancestors")).toBe("frame-ancestors 'none'")
    // task 21.8: la directiva de scripts cambió con D3 (nonce + `strict-dynamic`,
    // sin permisos en línea; `unsafe-eval` sólo fuera de producción, que es el caso
    // de esta suite). Lo que este test sigue custodiando es que el HOST de
    // Turnstile no se perdió y que youtube-nocookie no se filtró acá.
    expect(getDirective(csp, "script-src")).toBe(
      `script-src 'self' 'nonce-${NONCE}' 'strict-dynamic' 'wasm-unsafe-eval' 'unsafe-eval' https://challenges.cloudflare.com`
    )
  })
})
