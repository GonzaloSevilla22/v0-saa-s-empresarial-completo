/**
 * multiusuario-operativo tanda C (17.3) — del error de la API de invitaciones al mensaje.
 */
import { describe, it, expect } from "vitest"
import { classifyInvitationFailure, invitationErrorMessage } from "@/lib/invitation-errors"
import { PythonApiError } from "@/lib/api/python-api-error"

const err = (message: string, status: number, code?: string) => new PythonApiError(message, status, { code })

describe("invitationErrorMessage", () => {
  it.each([
    [err("invitation_cooldown: esperá unos minutos", 429, "P0439"), /esper[áa] unos minutos/i],
    [err("invitation_daily_cap: tope diario", 429, "P0439"), /por d[ií]a/i],
    [err("Demasiadas", 429, "P0439"), /demasiadas solicitudes/i],
    [err("P409: pending invitation already exists for a@b.co", 409, "P0407"), /invitaci[óo]n pendiente/i],
    [err("invitation_not_pending: ya fue revocada", 409, "P0409"), /ya no est[áa] pendiente/i],
    [err("P403: member quota reached (2 / 2)", 403, "P0402"), /l[ií]mite de miembros/i],
    [err("Solo el owner puede invitar admins", 403, "P0403"), /solo el due[ñn]o/i],
    [err("invalid_email: la dirección no es válida", 400, "P0400"), /email/i],
    [err("Rol inválido en el conjunto de la invitación", 400, "P0400"), /rol/i],
    [err("insufficient_role: solo el dueño", 403, "P0403"), /permisos/i],
    [err("P404: invitation not found", 404, "P0404"), /ya no existe/i],
    [err("Unprocessable", 422), /email y los roles/i],
  ])("%#: traduce a un mensaje accionable", (error, expected) => {
    expect(invitationErrorMessage(error)).toMatch(expected)
  })

  it("el tope diario y el enfriamiento se distinguen (dicen cosas distintas al usuario)", () => {
    const cap = invitationErrorMessage(err("invitation_daily_cap", 429, "P0439"))
    const cooldown = invitationErrorMessage(err("invitation_cooldown", 429, "P0439"))
    expect(cap).not.toBe(cooldown)
  })

  it("un error desconocido conserva su texto; sin texto, uno genérico", () => {
    expect(invitationErrorMessage(new Error("algo raro"))).toBe("algo raro")
    expect(invitationErrorMessage(new Error(""))).toMatch(/no pudimos/i)
    expect(invitationErrorMessage(undefined)).toMatch(/no pudimos/i)
  })

  it("nunca imprime un token", () => {
    const token = "0123456789abcdef".repeat(4)
    expect(invitationErrorMessage(err("invitation_cooldown", 429, "P0439"))).not.toContain(token)
  })
})

describe("classifyInvitationFailure — la pantalla del invitado", () => {
  it("404 / P0404 = «no disponible»: junta vencida, revocada, usada, inexistente y de otra identidad", () => {
    expect(classifyInvitationFailure(err("P404: invalid or expired invitation token", 404, "P0404"))).toBe("unavailable")
    expect(classifyInvitationFailure(err("lo que sea", 404))).toBe("unavailable")
  })

  it("409 «ya es miembro»", () => {
    expect(classifyInvitationFailure(err("P409: caller is already a member of account x", 409, "P0409"))).toBe("already-member")
  })

  it("cupo del plan", () => {
    expect(classifyInvitationFailure(err("P403: member quota reached (2 / 2)", 403, "P0402"))).toBe("quota")
  })

  it("todo lo demás (red, 5xx, cuenta desfasada) es «other»: se puede reintentar", () => {
    expect(classifyInvitationFailure(err("boom", 500))).toBe("other")
    expect(classifyInvitationFailure(new Error("Failed to fetch"))).toBe("other")
    expect(classifyInvitationFailure(err("cambiaste de cuenta", 409, "account_switched"))).toBe("other")
  })
})
