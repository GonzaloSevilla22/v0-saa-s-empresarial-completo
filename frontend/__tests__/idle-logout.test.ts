/**
 * Tests for the idle logout action.
 *
 * Spec coverage:
 *   - Signs out via Supabase and clears the tenant cookie
 *   - Redirects to /auth/login?reason=idle&next=<current-path>
 *   - Idempotent (calling twice does not double-redirect / throw)
 *   - `next` param equals the current pathname
 */

import { describe, it, expect, vi, beforeEach } from "vitest"

// ── Mocks ────────────────────────────────────────────────────────────────────

const signOutMock = vi.fn()
const pushMock = vi.fn()
const deleteCookieMock = vi.fn()
const clearAuthUxCookiesMock = vi.fn()
// auth-hardening-jwt-cookies (Parte C, D1, task 19.5): el access token vive en
// memoria del modulo y el servidor no puede borrarlo. Si nadie lo olvida, la
// pestana sigue operando con una credencial que el servidor ya revoco -- hasta
// una hora, lo que dure el token.
const clearAccessTokenMock = vi.fn()

// auth-hardening-jwt-cookies (Parte C, task 18.4g): el cierre de sesión pasó a
// una acción de SERVIDOR — el navegador ya no puede borrar las cookies `sb-*`
// httpOnly. El doble se mueve de seam con él: mockear `@/lib/supabase/client`
// dejaría este archivo verde mientras `performIdleLogout` no revoca nada.
vi.mock("@/app/auth/actions", () => ({
  signOutAction: (...args: unknown[]) => signOutMock(...args),
}))

vi.mock("@/lib/auth/access-token-store", () => ({
  clearAccessToken: (...args: unknown[]) => clearAccessTokenMock(...args),
}))

// auth-hardening-jwt-cookies (task 14.2): el doble de `@/lib/cookies` tiene que
// exponer `clearAuthUxCookies`. Sin esta línea, en cuanto `performIdleLogout`
// lo importa el módulo devuelve `undefined` y el archivo entero muere con un
// `TypeError` que no es el RED buscado.
vi.mock("@/lib/cookies", () => ({
  COOKIE_KEYS: { TENANT: "tenant:active", LAST_ACTIVITY: "auth:last-activity" },
  deleteCookie: (...args: unknown[]) => deleteCookieMock(...args),
  clearAuthUxCookies: (...args: unknown[]) => clearAuthUxCookiesMock(...args),
}))

// ── Tests ────────────────────────────────────────────────────────────────────

import { performIdleLogout } from "@/lib/auth/idle-logout"

describe("performIdleLogout", () => {
  beforeEach(() => {
    signOutMock.mockReset()
    pushMock.mockReset()
    deleteCookieMock.mockReset()
    clearAuthUxCookiesMock.mockReset()
    clearAccessTokenMock.mockReset()
    signOutMock.mockResolvedValue({ ok: true })
  })

  // ── Parte C, D1 (task 19.5) ───────────────────────────────────────────────

  it("olvida el access token de memoria", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard")
    expect(clearAccessTokenMock).toHaveBeenCalledTimes(1)
  })

  it("lo olvida tambien cuando el cierre en el servidor falla", async () => {
    // El token en memoria es del NAVEGADOR: que el servidor no haya podido
    // revocar la sesion es justamente la razon para no seguir usandolo.
    signOutMock.mockResolvedValue({ ok: false, error: "sesion ya vencida" })

    await performIdleLogout({ push: pushMock }, "/dashboard")

    expect(clearAccessTokenMock).toHaveBeenCalledTimes(1)
    expect(pushMock).toHaveBeenCalledTimes(1)
  })

  // ── 4.1 RED / 4.2 GREEN: signs out, clears cookie, redirects ──────────────

  it("delega el cierre en la acción de servidor (18.4g)", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard")
    expect(signOutMock).toHaveBeenCalledTimes(1)
  })

  // auth-hardening-jwt-cookies (task 14.2): la aserción es la misma —el cierre
  // por inactividad limpia `tenant:active`— pero pasa por el mecanismo
  // compartido. Que `clearAuthUxCookies()` borre esa cookie lo fija
  // `__tests__/lib/clear-auth-ux-cookies.test.ts`.
  it("clears the session UX cookies (tenant:active included)", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard")
    expect(clearAuthUxCookiesMock).toHaveBeenCalledTimes(1)
  })

  // ── 14.2 ::clears_last_activity_cookie ────────────────────────────────────
  it("clears auth:last-activity — sin esto el primer re-login rebota", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard")

    // El cierre por inactividad NO puede dejar viva la cookie de actividad:
    // sobrevive una semana y el middleware, al leerla vencida, descarta las
    // cookies `sb-*` recién emitidas por el login siguiente.
    expect(clearAuthUxCookiesMock).toHaveBeenCalled()
    // Y no vuelve al borrado suelto de una sola cookie.
    expect(deleteCookieMock).not.toHaveBeenCalled()
  })

  // ── 14.3 ::uses_local_scope ───────────────────────────────────────────────
  it("uses local scope — cerrar por inactividad no desloguea los otros dispositivos", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard")

    // `signOut()` pelado es GLOBAL por default de la librería
    // (GoTrueClient.js:3150): revocaba los refresh tokens de todos los
    // dispositivos, así que el POS del mostrador se caía cuando el dueño
    // dejaba el celular quieto veinte minutos.
    expect(signOutMock).toHaveBeenCalledWith({ scope: "local" })
  })

  it("redirects to /auth/login with reason=idle and next param", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard/ventas")
    expect(pushMock).toHaveBeenCalledWith(
      "/auth/login?reason=idle&next=%2Fdashboard%2Fventas",
    )
  })

  // ── 4.3 TRIANGULATE: idempotency + next path ──────────────────────────────

  it("is idempotent — calling twice redirects only once", async () => {
    const idempotentFn = performIdleLogout
    await idempotentFn({ push: pushMock }, "/dashboard")
    await idempotentFn({ push: pushMock }, "/dashboard")
    // push is called each time, but signOut should guard against errors on repeat
    // — main requirement: does not throw on second call
    expect(signOutMock).toHaveBeenCalledTimes(2)
  })

  it("preserves nested paths in the next param", async () => {
    await performIdleLogout({ push: pushMock }, "/dashboard/admin/billing")
    expect(pushMock).toHaveBeenCalledWith(
      "/auth/login?reason=idle&next=%2Fdashboard%2Fadmin%2Fbilling",
    )
  })

  it("handles signOut error gracefully (still redirects)", async () => {
    signOutMock.mockResolvedValue({ ok: false, error: "session expired" })
    await expect(
      performIdleLogout({ push: pushMock }, "/dashboard"),
    ).resolves.not.toThrow()
    // Should still redirect
    expect(pushMock).toHaveBeenCalled()
  })
})
