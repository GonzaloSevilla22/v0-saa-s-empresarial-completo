/**
 * invitation-errors.ts — de un error de la API de invitaciones a un mensaje para la persona.
 *
 * multiusuario-operativo (tanda C, D10, D12, D13). Los P04xx de las RPCs llegan por FastAPI como
 * RFC 7807 (`PythonApiError`: `status`, `code` = sqlstate, `message` = el texto de la RPC):
 *
 *   P0402 (403)  cupo de usuarios del plan alcanzado
 *   P0403 (403)  falta de autoridad (el administrador no invita administradores / otro rol)
 *   P0407 (409)  ya hay una invitación pendiente para ese email
 *   P0409 (409)  `invitation_not_pending` (aceptada o revocada) o «ya es miembro»
 *   P0404 (404)  la invitación no existe, venció, se revocó o es de otra identidad
 *   P0439 (429)  tope de envío: `invitation_cooldown` / `invitation_daily_cap`
 *   P0400 (400)  email inválido / rol fuera del catálogo
 *
 * Módulo puro (sin React): lo consumen el formulario de invitar, la lista de pendientes y la
 * pantalla de aceptación. Reconoce el error por su FORMA (`status` / `code` / texto) y no por
 * `instanceof`, para no acoplarse al módulo de `python-client` (que exige `NEXT_PUBLIC_BACKEND_URL`
 * al importarse).
 */

interface ApiErrorLike {
  message: string
  status?: number
  code?: string
}

function asApiError(error: unknown): ApiErrorLike {
  if (error instanceof Error) {
    const e = error as Error & { status?: unknown; code?: unknown }
    return {
      message: e.message ?? "",
      status: typeof e.status === "number" ? e.status : undefined,
      code: typeof e.code === "string" ? e.code : undefined,
    }
  }
  return { message: typeof error === "string" ? error : "" }
}

function has(text: string, needle: string): boolean {
  return text.toLowerCase().includes(needle.toLowerCase())
}

/** Mensaje para la persona que invita (crear, reenviar, revocar, listar). */
export function invitationErrorMessage(error: unknown): string {
  const { message, status, code } = asApiError(error)

  if (status === 429 || code === "P0439") {
    if (has(message, "invitation_daily_cap")) {
      return "Alcanzaste el máximo de invitaciones por día para tu negocio. Probá de nuevo mañana."
    }
    if (has(message, "invitation_cooldown")) {
      return "Esperá unos minutos antes de volver a enviar esta invitación."
    }
    return "Demasiadas solicitudes. Esperá un momento y volvé a intentar."
  }
  if (code === "P0407" || has(message, "pending invitation already exists")) {
    return "Ya existe una invitación pendiente para ese email."
  }
  if (has(message, "invitation_not_pending")) {
    return "Esa invitación ya no está pendiente: se aceptó o se revocó."
  }
  if (code === "P0402" || has(message, "member quota reached")) {
    return "Alcanzaste el límite de miembros de tu plan."
  }
  if (has(message, "solo el owner puede invitar admins")) {
    return "Solo el dueño puede invitar con los roles de propietario o administrador."
  }
  if (has(message, "invalid_email")) {
    return "Revisá el email: no es una dirección válida."
  }
  if (code === "P0400") {
    return "Revisá los datos de la invitación: algún rol no es válido."
  }
  if (status === 403 || code === "P0403" || code === "P0401") {
    return "No tenés permisos para gestionar invitaciones."
  }
  if (status === 404 || code === "P0404") {
    return "Esa invitación ya no existe."
  }
  if (status === 422) {
    return "Revisá el email y los roles: alguno no es válido."
  }
  return message || "No pudimos completar la operación. Probá de nuevo."
}

/** Por qué falló la vista previa o la aceptación, para elegir la pantalla. */
export type InvitationFailure = "unavailable" | "already-member" | "quota" | "other"

/**
 * Clasificación para el invitado. `unavailable` junta, A PROPÓSITO, a la invitación vencida, revocada,
 * ya usada, inexistente y a la de otra identidad: la base responde LO MISMO (P0404) para que la
 * pantalla no confirme que un token existe.
 */
export function classifyInvitationFailure(error: unknown): InvitationFailure {
  const { message, status, code } = asApiError(error)
  if (status === 404 || code === "P0404") return "unavailable"
  if (status === 409 && (code === "P0409" || has(message, "already a member"))) return "already-member"
  if (code === "P0402" || has(message, "member quota reached")) return "quota"
  return "other"
}
