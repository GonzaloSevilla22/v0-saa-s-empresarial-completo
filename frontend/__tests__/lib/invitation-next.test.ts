/**
 * multiusuario-operativo tanda C (17.2) — la allow-list de retorno del registro.
 *
 * El registro hasta hoy no aceptaba ningún destino del cliente: el `emailRedirectTo` lo fija el
 * servidor. Para que quien se registra desde un link de invitación VUELVA a esa invitación, se
 * admite un `next`, pero SOLO la ruta de una invitación con un token que tiene forma de token.
 * Cualquier otro destino se descarta (sería el open redirect que auth-hardening-jwt-cookies D5
 * cerró).
 */
import { describe, it, expect } from "vitest"
import {
  INVITATION_ROUTE_PREFIX,
  invitationPath,
  isInvitationToken,
  safeInvitationNext,
} from "@/lib/auth/invitation-next"
import { isPublicPath, isProtectedPath } from "@/lib/auth/route-access"

const TOKEN = "0123456789abcdef".repeat(4)

describe("safeInvitationNext — la única ruta que el registro acepta del cliente", () => {
  it("acepta /invitacion/<token>", () => {
    expect(safeInvitationNext(`/invitacion/${TOKEN}`)).toBe(`/invitacion/${TOKEN}`)
    expect(safeInvitationNext("/invitacion/abc-DEF_0123456789abcdef")).toBe("/invitacion/abc-DEF_0123456789abcdef")
  })

  it.each([
    ["nulo", null],
    ["indefinido", undefined],
    ["vacío", ""],
    ["otro destino interno", "/dashboard"],
    ["otro destino interno de auth", "/auth/reset-password"],
    ["protocol-relative", `//evil.example/invitacion/${TOKEN}`],
    ["URL absoluta", `https://evil.example/invitacion/${TOKEN}`],
    ["URL absoluta del propio sitio", `https://www.aliadata.com.ar/invitacion/${TOKEN}`],
    ["backslash", `/\\evil.example`],
    ["token corto", "/invitacion/abc"],
    ["token largo", `/invitacion/${"a".repeat(200)}`],
    ["sin token", "/invitacion/"],
    ["sólo el prefijo", "/invitacion"],
    ["segmento extra", `/invitacion/${TOKEN}/extra`],
    ["con query", `/invitacion/${TOKEN}?x=1`],
    ["con hash", `/invitacion/${TOKEN}#x`],
    ["traversal", `/invitacion/../dashboard`],
    ["traversal codificado", `/invitacion/%2e%2e%2fdashboard`],
    ["con espacio", `/invitacion/${TOKEN} `],
    ["con salto de línea", `/invitacion/${TOKEN}\n`],
    ["con tabulador adelante", `/\t/evil.example`],
    ["otro prefijo parecido", `/invitaciones/${TOKEN}`],
    ["mayúsculas del prefijo", `/Invitacion/${TOKEN}`],
  ])("descarta %s", (_label, value) => {
    expect(safeInvitationNext(value as string | null | undefined)).toBeNull()
  })
})

describe("invitationPath / isInvitationToken", () => {
  it("arma la ruta con el token codificado", () => {
    expect(invitationPath(TOKEN)).toBe(`${INVITATION_ROUTE_PREFIX}/${TOKEN}`)
    expect(invitationPath("a/b c")).toBe("/invitacion/a%2Fb%20c")
  })

  it("reconoce la forma de un token y nada más", () => {
    expect(isInvitationToken(TOKEN)).toBe(true)
    for (const bad of ["", "corto", "con espacios en el medio 0123456789", "../../etc/passwd", null, undefined]) {
      expect(isInvitationToken(bad as string | null | undefined)).toBe(false)
    }
  })

  it("la ruta que arma es la que route-access declara pública (no se la gatea tras el login)", () => {
    expect(isPublicPath(invitationPath(TOKEN))).toBe(true)
    expect(isProtectedPath(invitationPath(TOKEN))).toBe(false)
  })
})
