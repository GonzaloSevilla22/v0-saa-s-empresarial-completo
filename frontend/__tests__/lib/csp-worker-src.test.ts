/**
 * Tests for the Content-Security-Policy `worker-src` directive
 * (frontend/lib/supabase/middleware.ts → buildContentSecurityPolicy),
 * design.md D7 / spec `immersive-3d-surfaces` Requirement "Assets self-hosted
 * compatibles con el CSP" — Scenario "CSP permite los workers de decode".
 *
 * `worker-src` was previously undeclared, inheriting `default-src 'self'`,
 * which blocks `blob:` Web Workers — the mechanism R3F/drei's Draco/KTX2
 * decoders use. Diff is EXACTLY `worker-src 'self' blob:` added — no other
 * directive touches, no third-party host added (regla de memoria: el CSP de
 * este proyecto ya bloqueó embeds de terceros una vez — verificar todo
 * cambio de CSP contra el resto de las directivas).
 *
 * Cycle: RED → GREEN → TRIANGULATE.
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

describe("buildContentSecurityPolicy — worker-src para decoders 3D self-hosted", () => {
  // ── RED → GREEN: worker-src permite self + blob: ─────────────────────────
  it("declares worker-src 'self' blob: (needed by Draco/KTX2 decoder Web Workers)", () => {
    const workerSrc = getDirective(buildContentSecurityPolicy(NONCE), "worker-src")
    expect(workerSrc).toBe("worker-src 'self' blob:")
  })

  // ── TRIANGULATE: no third-party host anywhere in worker-src ──────────────
  it("does not allow any third-party host in worker-src", () => {
    const workerSrc = getDirective(buildContentSecurityPolicy(NONCE), "worker-src")
    expect(workerSrc).not.toMatch(/https?:/)
  })

  // ── TRIANGULATE: minimal diff — every other directive stays byte-for-byte intact ──
  it("keeps every other directive exactly as before (minimal diff)", () => {
    const csp = buildContentSecurityPolicy(NONCE)
    expect(getDirective(csp, "default-src")).toBe("default-src 'self'")
    // task 21.8: idem — la forma nueva de `script-src` (D3) con `unsafe-eval` por
    // estar fuera de producción. El "diff mínimo" que este test cuida es el de
    // `worker-src`, que sigue intacto.
    expect(getDirective(csp, "script-src")).toBe(
      `script-src 'self' 'nonce-${NONCE}' 'strict-dynamic' 'wasm-unsafe-eval' 'unsafe-eval' https://challenges.cloudflare.com`,
    )
    expect(getDirective(csp, "style-src")).toBe("style-src 'self' 'unsafe-inline'")
    expect(getDirective(csp, "img-src")).toBe("img-src 'self' data: blob: https:")
    expect(getDirective(csp, "font-src")).toBe("font-src 'self' data:")
    expect(getDirective(csp, "frame-src")).toBe(
      "frame-src https://challenges.cloudflare.com https://www.youtube-nocookie.com",
    )
    expect(getDirective(csp, "frame-ancestors")).toBe("frame-ancestors 'none'")
  })
})
