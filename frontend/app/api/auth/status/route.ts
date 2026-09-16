/**
 * GET /api/auth/status — el estado de verificación del email, desde el servidor.
 *
 * auth-hardening-jwt-cookies (Parte C, D18). `/auth/verify-email` es la pantalla
 * que **todo usuario nuevo** mira, y sus cuatro mecanismos morían con D1:
 * `refreshSession()`, `getSession()` ×2 y `onAuthStateChange` — con `accessToken`
 * configurado, los cuatro **lanzan** (`supabase-js/index.mjs:389`). Este endpoint
 * los reemplaza: lee la cookie `HttpOnly`, consulta el estado **contra el
 * proveedor** y devuelve `{ email, email_confirmed_at }`. Ningún token, nunca.
 *
 * Endpoint aparte del manejador de token a propósito (D18): ése es de camino
 * caliente, idle-gated y con single-flight; éste es explícitamente el camino caro
 * y poco frecuente. Mezclarlos metería dos regímenes de cacheo y de
 * deduplicación distintos en la misma ruta.
 *
 * ── Desvío deliberado respecto de la letra de D18 ───────────────────────────
 *
 * D18 dice "**fuerza** una renovación contra el proveedor (que es la única forma
 * de observar un `email_confirmed_at` recién cambiado)". Se cumple el objetivo con
 * `getUser()` —que pega a `GET /auth/v1/user`— y no con `refreshSession()`, y es
 * una mejora, no un atajo:
 *
 *  - `getUser()` devuelve la fila **actual** del usuario, así que ve la
 *    verificación recién hecha igual que un refresh, **incluso** cuando el enlace
 *    se abrió en otro navegador — el caso donde la sesión de esta pestaña no
 *    cambió y un refresh no traería nada nuevo.
 *  - La pantalla sondea cada 4 s. Con `refreshSession()` eso son ~15 rotaciones
 *    de refresh token por minuto, justo el tráfico que D19-5 identifica como
 *    fuente de carreras perdidas contra el manejador de token. Un logout duro por
 *    una carrera, en la pantalla de verificación, sería el peor lugar posible.
 *
 * Lo que D18 rechaza —`getSession()` a secas, que se conforma con la cookie
 * cacheada— sigue rechazado: el endpoint habla con el proveedor en cada consulta,
 * y hay un test que lo fija.
 */
import { NextResponse, type NextRequest } from "next/server"
import type { AuthStatus } from "@/lib/auth/session-status"
import {
  clearSessionCookies,
  hasSessionCookie,
  isCrossSiteRequest,
  isIdleSession,
  revokeSession,
  serverClientForRequest,
  withSessionRouteHeaders,
  type CookieToSet,
} from "@/lib/auth/route-session"

/** Nunca se pre-renderiza: la respuesta depende de la cookie de la petición. */
export const dynamic = "force-dynamic"

/**
 * El contrato de respuesta vive en `lib/auth/session-status.ts`, junto a su
 * único cliente: una sola definición, imposible de desalinear.
 */
export type AuthStatusPayload = AuthStatus

/** Forma única de "no sé nada de vos": sin sesión, sesión ilegible u ociosa. */
const NO_SESSION: AuthStatusPayload = { email: null, email_confirmed_at: null }

function respond(payload: AuthStatusPayload, status = 200): NextResponse {
  return withSessionRouteHeaders(NextResponse.json(payload, { status }))
}

export async function GET(request: NextRequest): Promise<NextResponse> {
  // El email es PII: la lectura cross-site se rechaza igual que en el manejador
  // de token, y por la misma razón de fondo.
  if (isCrossSiteRequest(request)) return respond(NO_SESSION, 403)

  if (!hasSessionCookie(request)) return respond(NO_SESSION)

  if (isIdleSession(request)) {
    await revokeSession(request, "api/auth/status")
    const response = respond(NO_SESSION)
    clearSessionCookies(request, response)
    return response
  }

  // Las cookies que `getUser()` rote se aplican a la respuesta: si el access
  // token venció mientras el usuario miraba su bandeja de entrada, la rotación
  // que ocurre acá tiene que llegar al navegador o la próxima consulta presenta
  // un refresh token ya usado.
  const cookiesToSet: CookieToSet[] = []
  const supabase = serverClientForRequest(request, cookiesToSet)

  let email: string | null = null
  let emailConfirmedAt: string | null = null
  try {
    const { data, error } = await supabase.auth.getUser()
    if (!error && data.user) {
      email = data.user.email ?? null
      emailConfirmedAt = data.user.email_confirmed_at ?? null
    }
  } catch (unreadable) {
    // Misma razón que en el manejador de token: una cookie corrupta **lanza** en
    // vez de devolver `{ error }`. Una sesión ilegible es una sesión ausente.
    console.warn("[api/auth/status] cookie de sesión ilegible; se responde sin sesión:", unreadable)
    return respond(NO_SESSION)
  }

  const response = respond({ email, email_confirmed_at: emailConfirmedAt })
  for (const { name, value, options } of cookiesToSet) {
    response.cookies.set(name, value, options)
  }
  return response
}
