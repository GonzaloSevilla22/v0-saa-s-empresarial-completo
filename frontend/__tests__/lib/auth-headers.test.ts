/**
 * auth-hardening-jwt-cookies — D7 y D21, tasks 14.7 y 14.8.
 *
 * Dos defectos que comparten causa: cada transporte del navegador hacia el
 * backend propio armaba sus encabezados por su cuenta.
 *
 *  - Tres de ellos mandaban `Authorization: Bearer ` **vacío** cuando no había
 *    sesión, en vez de omitir el encabezado.
 *  - `python-client.ts:54` mergeaba `extraHeaders` DESPUÉS de los de auth, así
 *    que un caller podía sobrescribir `Authorization`.
 *
 * `getAuthHeaders()` es la única implementación: omite el encabezado cuando no
 * hay token y aplica los de auth ÚLTIMOS, de modo que el orden de merge deje de
 * ser una decisión de cada call site.
 *
 * `handleUnauthorized()` cierra D7: el 401 dejaba un mensaje que recomendaba
 * recargar la página, y esa recomendación delegaba la renovación en un redirect
 * del middleware que en las 12 rutas de F1 **nunca ocurría**.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const getSessionMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ auth: { getSession: getSessionMock } }),
}))

import { getAuthHeaders, handleUnauthorized, sessionNavigation } from "@/lib/api/auth-headers"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

function withSession(token: string) {
  getSessionMock.mockResolvedValue({ data: { session: { access_token: token } } })
}
function withoutSession() {
  getSessionMock.mockResolvedValue({ data: { session: null } })
}

beforeEach(() => {
  vi.restoreAllMocks()
  getSessionMock.mockReset()
})

// ── 14.8 ::omits_authorization_header_when_token_is_empty ──────────────────
describe("getAuthHeaders — nunca manda un Bearer vacío", () => {
  it("omite el encabezado cuando no hay sesión", async () => {
    withoutSession()
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBeUndefined()
    expect(Object.keys(headers)).not.toContain("Authorization")
  })

  it("omite el encabezado cuando el token es una cadena vacía", async () => {
    getSessionMock.mockResolvedValue({ data: { session: { access_token: "" } } })
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBeUndefined()
  })

  it("omite el encabezado cuando la consulta de sesión falla", async () => {
    getSessionMock.mockRejectedValue(new Error("red caída"))
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBeUndefined()
  })

  it("lo incluye cuando hay token", async () => {
    withSession("tok-123")
    const headers = await getAuthHeaders()
    expect(headers.Authorization).toBe("Bearer tok-123")
  })
})

describe("getAuthHeaders — los encabezados de auth van ÚLTIMOS", () => {
  it("un caller no puede sobrescribir Authorization", async () => {
    withSession("tok-real")
    const headers = await getAuthHeaders({ Authorization: "Bearer tok-del-caller" })
    expect(headers.Authorization).toBe("Bearer tok-real")
  })

  it("los demás encabezados del caller se conservan", async () => {
    withSession("tok-123")
    const headers = await getAuthHeaders({
      "Content-Type": "application/json",
      "Idempotency-Key": "key-abc",
    })
    expect(headers).toMatchObject({
      "Content-Type": "application/json",
      "Idempotency-Key": "key-abc",
      Authorization: "Bearer tok-123",
    })
  })

  it("sin token, un Authorization del caller tampoco sobrevive con valor vacío", async () => {
    withoutSession()
    const headers = await getAuthHeaders({ "Content-Type": "application/json" })
    expect(headers).toEqual({ "Content-Type": "application/json" })
  })
})

// ── 14.7 ::401_without_session_navigates_to_login ──────────────────────────
describe("handleUnauthorized — D7", () => {
  it("sin sesión navega al login con reason=expired y el destino actual", async () => {
    withoutSession()
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})
    window.history.pushState({}, "", "/caja?turno=2")

    const navigated = await handleUnauthorized()

    expect(navigated).toBe(true)
    expect(assign).toHaveBeenCalledTimes(1)
    const url = new URL(assign.mock.calls[0][0], "https://app.test")
    expect(url.pathname).toBe("/auth/login")
    expect(url.searchParams.get("reason")).toBe("expired")
    expect(url.searchParams.get("next")).toBe("/caja?turno=2")
  })

  it("con sesión viva NO navega: el 401 fue por otra razón", async () => {
    withSession("tok-vivo")
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    const navigated = await handleUnauthorized()

    expect(navigated).toBe(false)
    expect(assign).not.toHaveBeenCalled()
  })

  it("si la consulta de sesión falla, trata la sesión como ausente y navega", async () => {
    getSessionMock.mockRejectedValue(new Error("red caída"))
    const assign = vi.spyOn(sessionNavigation, "assign").mockImplementation(() => {})

    const navigated = await handleUnauthorized()

    expect(navigated).toBe(true)
    expect(assign).toHaveBeenCalled()
  })
})

// ── D21: una sola implementación arma los encabezados ──────────────────────
describe("D21 — los transportes de la Parte B no arman el Bearer a mano", () => {
  const TRANSPORTS = [
    "lib/api/python-client.ts",
    "lib/api/subscriptions-client.ts",
    "components/ventas/sale-receipt-button.tsx",
    "app/(dashboard)/admin/pagos/page.tsx",
  ]

  it.each(TRANSPORTS)("%s consume getAuthHeaders()", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    expect(source).toContain("getAuthHeaders")
    expect(source).toContain("@/lib/api/auth-headers")
  })

  it.each(TRANSPORTS)("%s ya no construye `Bearer ${…}` por su cuenta", (relative) => {
    const source = fs.readFileSync(path.join(FRONTEND, relative), "utf8")
    const handRolled = source
      .split(/\r?\n/)
      .filter((line) => !line.trimStart().startsWith("//") && !line.trimStart().startsWith("*"))
      .filter((line) => /Bearer\s*\$\{/.test(line))
    expect(handRolled, `armado a mano en ${relative}: ${handRolled.join(" | ")}`).toEqual([])
  })

  it("el detector reconoce el armado a mano (no es vacuo)", () => {
    const offending = 'Authorization: `Bearer ${session?.access_token ?? ""}`'
    expect(/Bearer\s*\$\{/.test(offending)).toBe(true)
  })

  it("y el único sitio que compone el encabezado es el helper compartido", () => {
    const helper = fs.readFileSync(path.join(FRONTEND, "lib/api/auth-headers.ts"), "utf8")
    expect(/Bearer\s*\$\{/.test(helper)).toBe(true)
  })
})
