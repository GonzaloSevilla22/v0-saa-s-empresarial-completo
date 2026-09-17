/**
 * auth-hardening-jwt-cookies — Parte C, D1, task 19.8d.
 *
 * Las trece pantallas de `/admin` resolvían su gate con `supabase.auth.getUser()`
 * + un `SELECT role FROM profiles`. Con el cliente configurado con `accessToken`
 * ese `getUser()` **lanza** (`supabase-js/index.mjs:389`), así que el gate pasa al
 * contexto de sesión de la app, que ya tiene las dos cosas.
 *
 * Este archivo fija la decisión del hook y, con un barrido de fuente, que las
 * trece pantallas lo consumen en vez de volver a copiarla.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook } from "@testing-library/react"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

const replaceMock = vi.fn()
const authState = { user: null as { id: string } | null, isAdmin: false }

vi.mock("next/navigation", () => ({
  useRouter: () => ({ replace: replaceMock, push: vi.fn() }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => authState,
}))

import { useAdminGate } from "@/hooks/auth/use-admin-gate"

beforeEach(() => {
  replaceMock.mockReset()
  authState.user = null
  authState.isAdmin = false
})

describe("useAdminGate — la decisión", () => {
  it("con usuario admin permite y no navega", () => {
    authState.user = { id: "u-1" }
    authState.isAdmin = true

    const { result } = renderHook(() => useAdminGate())

    expect(result.current).toBe("allowed")
    expect(replaceMock).not.toHaveBeenCalled()
  })

  it("con usuario NO admin deniega y manda al dashboard", () => {
    authState.user = { id: "u-1" }
    authState.isAdmin = false

    const { result } = renderHook(() => useAdminGate())

    expect(result.current).toBe("denied")
    expect(replaceMock).toHaveBeenCalledWith("/dashboard")
  })

  it("sin sesión manda al login REAL, no a `/auth`", () => {
    // `app/auth/page.tsx` no existe: el `window.location.href = '/auth'` que
    // tenían las trece pantallas era un 404, misma familia que el hallazgo F2 de
    // la Parte B.
    const { result } = renderHook(() => useAdminGate())

    expect(result.current).toBe("denied")
    expect(replaceMock).toHaveBeenCalledWith("/auth/login")
    expect(replaceMock).not.toHaveBeenCalledWith("/auth")
  })

  it("sin sesión no manda además al dashboard (una sola navegación)", () => {
    renderHook(() => useAdminGate())
    expect(replaceMock).toHaveBeenCalledTimes(1)
  })
})

describe("las pantallas de /admin consumen el gate compartido", () => {
  const ADMIN_SCREENS = [
    "app/(dashboard)/admin/analytics/page.tsx",
    "app/(dashboard)/admin/metricas/page.tsx",
    "app/(dashboard)/admin/metricas/ai/page.tsx",
    "app/(dashboard)/admin/metricas/clientes/page.tsx",
    "app/(dashboard)/admin/metricas/compras/page.tsx",
    "app/(dashboard)/admin/metricas/comunidad/page.tsx",
    "app/(dashboard)/admin/metricas/cursos/page.tsx",
    "app/(dashboard)/admin/metricas/gastos/page.tsx",
    "app/(dashboard)/admin/metricas/simulador/page.tsx",
    "app/(dashboard)/admin/metricas/stock/page.tsx",
    "app/(dashboard)/admin/metricas/ventas/page.tsx",
    "app/(dashboard)/admin/pagos/page.tsx",
    "app/(dashboard)/admin/pagos/ambiguas/page.tsx",
  ]

  const read = (relative: string) => fs.readFileSync(path.join(FRONTEND, relative), "utf8")

  it.each(ADMIN_SCREENS)("%s usa useAdminGate", (relative) => {
    const source = read(relative)
    expect(source).toContain("useAdminGate")
    expect(source).toContain("@/hooks/auth/use-admin-gate")
  })

  it.each(ADMIN_SCREENS)("%s ya no consulta el rol en profiles", (relative) => {
    const source = read(relative)
    // La cuarta copia de un dato que el contexto ya tiene.
    expect(source).not.toMatch(/from\((["'])profiles\1\)/)
  })

  it.each(ADMIN_SCREENS)("%s ya no navega a `/auth` ni con window.location", (relative) => {
    const source = read(relative)
    expect(source).not.toMatch(/(["'])\/auth\1/)
    expect(source).not.toContain("window.location.href")
  })

  it("los detectores no son vacuos", () => {
    const viejo = `
      const { data: profile } = await supabase.from('profiles').select('role').eq('id', user.id).single()
      if (!user) { window.location.href = '/auth'; return }
    `
    expect(/from\((["'])profiles\1\)/.test(viejo)).toBe(true)
    expect(/(["'])\/auth\1/.test(viejo)).toBe(true)
    expect(viejo.includes("window.location.href")).toBe(true)
  })
})
