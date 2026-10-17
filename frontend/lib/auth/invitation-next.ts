/**
 * invitation-next.ts — la ruta de una invitación y su allow-list de retorno.
 *
 * multiusuario-operativo (tanda C, D12). El link del email lleva a
 * `/invitacion/<token>`. Quien lo abre sin sesión elige «Ingresar» o «Crear cuenta», y al
 * completar el acceso tiene que VOLVER a esa misma invitación: el login ya admite cualquier
 * ruta interna por `safeNext()`, pero el registro hasta hoy no aceptaba ningún destino del
 * cliente (el `emailRedirectTo` lo fija el servidor).
 *
 * Abrirle al registro un `next` general sería exactamente el open redirect que
 * auth-hardening-jwt-cookies (D5) cerró. Por eso acá vive una allow-list ESTRECHA: el único
 * destino que el registro acepta del cliente es la propia ruta de una invitación, con un token
 * que tiene forma de token. Cualquier otra cosa se descarta y el registro sigue como siempre.
 *
 * Módulo puro (sin React ni Next): lo consumen la página de registro, la de verificación de
 * email, la de la invitación y —re-validando, porque el cliente no es de fiar— la acción de
 * servidor `signUpAction`.
 */

/** Prefijo público de la ruta de aceptación (el mismo que declara `lib/auth/route-access.ts`). */
export const INVITATION_ROUTE_PREFIX = "/invitacion"

/** Un token de invitación es hex de 64 caracteres; se admite un rango razonable de base64url. */
const TOKEN_SHAPE = /^[A-Za-z0-9_-]{16,128}$/

/** ¿Tiene forma de token de invitación? (No dice nada de si existe: eso lo decide la base.) */
export function isInvitationToken(value: string | null | undefined): value is string {
  return typeof value === "string" && TOKEN_SHAPE.test(value)
}

/** `/invitacion/<token>`; el token se codifica por si algún día deja de ser hex. */
export function invitationPath(token: string): string {
  return `${INVITATION_ROUTE_PREFIX}/${encodeURIComponent(token)}`
}

/** El link completo de aceptación (`<origen>/invitacion/<token>`): lo que se copia, nunca el token suelto. */
export function invitationLink(token: string, origin: string): string {
  return `${origin}${invitationPath(token)}`
}

/**
 * Devuelve `next` SOLO si es exactamente la ruta de una invitación (`/invitacion/<token>`, sin
 * query, sin hash, sin segmentos extra); si no, `null`. Es la allow-list del registro.
 */
export function safeInvitationNext(next: string | null | undefined): string | null {
  if (typeof next !== "string") return null
  const prefix = `${INVITATION_ROUTE_PREFIX}/`
  if (!next.startsWith(prefix)) return null
  const token = next.slice(prefix.length)
  return isInvitationToken(token) ? `${prefix}${token}` : null
}
