/**
 * auth-hardening-jwt-cookies — D6, task 14.1.
 *
 * Los tres caminos de cierre de sesión borraban cosas distintas:
 *   - `logout()` (auth-context.tsx:298) borraba sólo `tenant:active`,
 *   - `performIdleLogout()` (idle-logout.ts:50) borraba sólo `tenant:active`,
 *   - `closeAllSessions()` (auth-context.tsx:341-347) no borraba **ninguna**.
 *
 * El único lugar que borraba `auth:last-activity` era el middleware. De ahí
 * salía el bounce del **primer** re-login post-idle: la cookie de actividad
 * sobrevivía con `max-age` de una semana y el middleware descartaba las
 * cookies `sb-*` recién emitidas.
 *
 * `clearAuthUxCookies()` es el mecanismo compartido por los tres.
 */
import { describe, it, expect, beforeEach } from "vitest"
import { clearAuthUxCookies, setCookie, getClientCookie, COOKIE_KEYS } from "@/lib/cookies"

function seedBothCookies() {
  setCookie(COOKIE_KEYS.LAST_ACTIVITY, "1789000000000")
  setCookie(COOKIE_KEYS.TENANT, "acc-1")
}

beforeEach(() => {
  clearAuthUxCookies()
})

describe("clearAuthUxCookies", () => {
  it("borra auth:last-activity", () => {
    seedBothCookies()
    expect(getClientCookie(COOKIE_KEYS.LAST_ACTIVITY)).toBe("1789000000000")

    clearAuthUxCookies()

    expect(getClientCookie(COOKIE_KEYS.LAST_ACTIVITY)).toBeNull()
  })

  it("borra tenant:active", () => {
    seedBothCookies()
    expect(getClientCookie(COOKIE_KEYS.TENANT)).toBe("acc-1")

    clearAuthUxCookies()

    expect(getClientCookie(COOKIE_KEYS.TENANT)).toBeNull()
  })

  it("borra las dos en la misma llamada", () => {
    seedBothCookies()

    clearAuthUxCookies()

    expect(getClientCookie(COOKIE_KEYS.LAST_ACTIVITY)).toBeNull()
    expect(getClientCookie(COOKIE_KEYS.TENANT)).toBeNull()
  })

  it("es idempotente: no explota si no había ninguna", () => {
    expect(() => {
      clearAuthUxCookies()
      clearAuthUxCookies()
    }).not.toThrow()
    expect(getClientCookie(COOKIE_KEYS.TENANT)).toBeNull()
  })

  it("no toca las cookies de preferencia de UI", () => {
    setCookie(COOKIE_KEYS.THEME, "dark")
    setCookie(COOKIE_KEYS.SIDEBAR, "collapsed")
    seedBothCookies()

    clearAuthUxCookies()

    expect(getClientCookie(COOKIE_KEYS.THEME)).toBe("dark")
    expect(getClientCookie(COOKIE_KEYS.SIDEBAR)).toBe("collapsed")
  })
})
