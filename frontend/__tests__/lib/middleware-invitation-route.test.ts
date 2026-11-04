/**
 * multiusuario-operativo tanda C (17.2, D12) — la ruta pública /invitacion/[token].
 *
 * El token viaja en el PATH. Dos consecuencias que este test fija en el middleware:
 *
 *  1. La ruta es PÚBLICA: un visitante sin sesión llega a la pantalla (que le muestra el mensaje
 *     genérico y los accesos «Ingresar» / «Crear cuenta»); no se lo manda al login con un
 *     redirect que perdería la invitación.
 *  2. El token NO puede salir por `Referer` hacia ningún tercero ni quedar indexado:
 *     `Referrer-Policy: no-referrer` (el global es `strict-origin-when-cross-origin`, que a un
 *     destino del mismo origen sí manda el path completo) y `X-Robots-Tag: noindex`. Sólo para
 *     esa ruta: el resto de la app conserva la política global.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

vi.mock("@supabase/ssr", async () => {
  const mod = await import("./helpers/middleware-harness")
  return { createServerClient: mod.createServerClientMock }
})

import { harness, resetHarness, buildRequest, isRedirect } from "./helpers/middleware-harness"
import { updateSession } from "@/lib/supabase/middleware"

const TOKEN = "0123456789abcdef".repeat(4)

beforeEach(() => {
  resetHarness()
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_URL", "https://project.supabase.co")
  vi.stubEnv("NEXT_PUBLIC_SUPABASE_ANON_KEY", "anon-key")
})

describe("updateSession — /invitacion/[token]", () => {
  it("sin sesión se sirve (no hay redirect al login): la pantalla decide qué mostrar", async () => {
    harness.user = null
    const response = await updateSession(buildRequest(`/invitacion/${TOKEN}`))
    expect(isRedirect(response)).toBe(false)
  })

  it("con sesión también se sirve", async () => {
    harness.user = { id: "u1", email_confirmed_at: "2026-01-01T00:00:00Z" }
    const response = await updateSession(
      buildRequest(`/invitacion/${TOKEN}`, { "auth:last-activity": String(Date.now()) }),
    )
    expect(isRedirect(response)).toBe(false)
  })

  it("la respuesta lleva Referrer-Policy: no-referrer y X-Robots-Tag: noindex", async () => {
    harness.user = null
    const response = await updateSession(buildRequest(`/invitacion/${TOKEN}`))
    expect(response.headers.get("Referrer-Policy")).toBe("no-referrer")
    expect(response.headers.get("X-Robots-Tag")).toMatch(/noindex/)
    expect(response.headers.get("X-Robots-Tag")).toMatch(/nofollow/)
  })

  it("el resto de las rutas conserva la política global y no se vuelve no indexable", async () => {
    harness.user = null
    for (const pathname of ["/", "/auth/login", "/legal/terminos"]) {
      const response = await updateSession(buildRequest(pathname))
      expect(response.headers.get("Referrer-Policy")).toBe("strict-origin-when-cross-origin")
      expect(response.headers.get("X-Robots-Tag")).toBeNull()
    }
  })

  it("una ruta protegida que redirige conserva la política global (el token no está en su path)", async () => {
    harness.user = null
    const response = await updateSession(buildRequest("/ventas"))
    expect(isRedirect(response)).toBe(true)
    expect(response.headers.get("Referrer-Policy")).toBe("strict-origin-when-cross-origin")
  })

  it("un prefijo parecido no es la ruta de invitación (no hereda la política ni queda público)", async () => {
    harness.user = null
    const response = await updateSession(buildRequest(`/invitaciones/${TOKEN}`))
    expect(isRedirect(response)).toBe(true) // protegida por defecto
    expect(response.headers.get("Referrer-Policy")).toBe("strict-origin-when-cross-origin")
  })
})
