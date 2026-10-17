/**
 * multiusuario-operativo tanda A (D4) — `refreshSessionAction`.
 *
 * El token handler (`GET /api/auth/token`) sólo renueva el access token cuando está a punto de
 * vencer (`getSession()` no llama a GoTrue antes). Pero el claim `app_metadata.account_id` lo
 * emite el HOOK, que sólo corre cuando GoTrue EMITE un token: elegir otra cuenta activa no
 * cambia nada del token vigente hasta una hora después. Esta acción de servidor fuerza la
 * renovación ante el proveedor (y reescribe las cookies de sesión rotadas, que el navegador
 * nunca ve) para que el cambio de cuenta rija YA.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"

const refreshSession = vi.fn()
const createServerClientSpy = vi.fn()

vi.mock("@/lib/supabase/server", () => ({
  createClient: () => {
    createServerClientSpy()
    return { auth: { refreshSession } }
  },
}))

vi.mock("next/headers", () => ({
  headers: async () => new Headers({ host: "aliadata.com.ar", "x-forwarded-proto": "https" }),
}))

import { refreshSessionAction } from "@/app/auth/actions"

beforeEach(() => {
  refreshSession.mockReset()
  createServerClientSpy.mockClear()
})

describe("refreshSessionAction", () => {
  it("fuerza la renovación ante el proveedor, desde el servidor, y responde ok", async () => {
    refreshSession.mockResolvedValue({ data: { session: { access_token: "t" } }, error: null })

    await expect(refreshSessionAction()).resolves.toEqual({ ok: true })

    expect(createServerClientSpy).toHaveBeenCalledTimes(1)
    expect(refreshSession).toHaveBeenCalledTimes(1)
  })

  it("un error del proveedor vuelve como resultado, no como excepción (y no filtra el token)", async () => {
    refreshSession.mockResolvedValue({ data: { session: null }, error: { message: "Invalid Refresh Token" } })
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})

    const result = await refreshSessionAction()

    expect(result).toEqual({ ok: false, error: "Invalid Refresh Token" })
    consoleError.mockRestore()
  })

  it("sin sesión en la respuesta (el proveedor no devolvió error ni sesión) NO se da por renovada", async () => {
    refreshSession.mockResolvedValue({ data: { session: null }, error: null })
    const consoleError = vi.spyOn(console, "error").mockImplementation(() => {})

    const result = await refreshSessionAction()

    expect(result.ok).toBe(false)
    consoleError.mockRestore()
  })
})
