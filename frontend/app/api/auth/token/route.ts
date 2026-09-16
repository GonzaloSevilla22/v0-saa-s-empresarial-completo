/**
 * GET /api/auth/token — el *token handler* del patrón que implementa D1.
 *
 * auth-hardening-jwt-cookies (Parte C, D1 + D19). La sesión vive en cookies
 * `HttpOnly` que el navegador ya no puede leer. Este manejador es el puente: lee
 * la cookie con el cliente de servidor, renueva si hace falta —reescribiendo las
 * cookies rotadas en su propia respuesta— y devuelve
 *
 *     { access_token, expires_at, user }
 *
 * **Nunca** el refresh token. Eso es todo el change: un XSS deja de poder
 * exfiltrar una credencial renovable de 400 días y se queda, como máximo, con un
 * access token de una hora que ya podía obtener llamando a la API.
 *
 * Las garantías de transporte (no cacheable, sin CORS, sólo same-origin) y la
 * decisión de inactividad viven en `lib/auth/route-session.ts`, compartidas con
 * `GET /api/auth/status`: dos criterios distintos de "sesión ociosa" en el
 * servidor divergen, y el que se relaja no da ningún error — deja de proteger.
 *
 * ── Lo propio de este manejador: single-flight (D19-5) ───────────────────────
 *
 * Después de la Parte C el navegador deja de refrescar y pasan a hacerlo N
 * contextos de servidor presentando el **mismo** refresh token. Una carrera
 * perdida es un logout duro a un usuario en medio de una venta. Acá se deduplica
 * por promesa en vuelo dentro del proceso y, cuando la petición ya llegó con
 * credenciales frescas (porque el middleware renovó antes en la misma petición),
 * se responde con lo que hay.
 *
 * ── Sobre la identidad que devuelve ─────────────────────────────────────────
 *
 * `user` se **decodifica del propio access token**, no se lee de `session.user`
 * ni se le pregunta a GoTrue. Dos razones:
 *
 *  - `session.user` en el servidor viene envuelto en el proxy de advertencia de
 *    auth-js, que emite un `console.warn` por cada acceso: en un camino que cada
 *    pestaña pide en cada carga, eso es spam de logs.
 *  - No agrega confianza. Este manejador **no toma ninguna decisión** con esa
 *    identidad: la reenvía junto al token, y quien la verifica de verdad es el
 *    servicio del otro lado (PostgREST y FastAPI comprueban la firma del mismo
 *    JWT). La identidad que el token afirma es exactamente la que el consumidor
 *    va a poder ejercer.
 *
 * Quien necesita identidad **autenticada contra el proveedor** —el estado de
 * verificación del email— tiene `GET /api/auth/status` (D18), que es el camino
 * caro y poco frecuente.
 */
import { NextResponse, type NextRequest } from "next/server"
import {
  clearSessionCookies,
  isCrossSiteRequest,
  isIdleSession,
  revokeSession,
  serverClientForRequest,
  withSessionRouteHeaders,
  type CookieToSet,
} from "@/lib/auth/route-session"

/** Nunca se pre-renderiza: la respuesta depende de la cookie de la petición. */
export const dynamic = "force-dynamic"

// ── Contrato de respuesta ───────────────────────────────────────────────────

export interface TokenHandlerUser {
  id: string
  email: string | null
}

export interface TokenHandlerPayload {
  access_token: string | null
  expires_at: number | null
  user: TokenHandlerUser | null
}

/**
 * Forma única de "no hay token para vos". Se usa para las cinco razones (sin
 * cookie, cookie ilegible, sesión inválida, refresh rechazado, sesión ociosa): el
 * navegador no necesita distinguirlas y el manejador no tiene por qué contarlas.
 */
const NO_SESSION: TokenHandlerPayload = {
  access_token: null,
  expires_at: null,
  user: null,
}

interface Resolution {
  payload: TokenHandlerPayload
  cookiesToSet: CookieToSet[]
}

// ── Identidad desde el token ────────────────────────────────────────────────

/**
 * Payload de un JWT, sin verificar la firma (ver el encabezado del módulo: acá
 * no se decide nada con esto).
 */
function decodeJwtPayload(token: string): Record<string, unknown> | null {
  const segments = token.split(".")
  if (segments.length !== 3) return null
  try {
    const padded = segments[1].replace(/-/g, "+").replace(/_/g, "/")
    return JSON.parse(Buffer.from(padded, "base64").toString("utf8")) as Record<string, unknown>
  } catch {
    return null
  }
}

function userFromAccessToken(token: string): TokenHandlerUser | null {
  const claims = decodeJwtPayload(token)
  const id = claims?.sub
  if (typeof id !== "string" || id === "") return null
  const email = claims?.email
  return { id, email: typeof email === "string" ? email : null }
}

// ── Single-flight por sesión (D19-5) ────────────────────────────────────────

/**
 * Renovaciones en vuelo, keyeadas por el **estado de las cookies de sesión** de
 * la petición: dos pedidos que llegan con el mismo tarro son el mismo estado y
 * deben compartir una sola renovación. Dos sesiones distintas nunca comparten
 * clave — si la clave fuera global, una cuenta recibiría el token de otra.
 *
 * Es por promesa **en vuelo**, no un caché: se borra al resolver. Un caché de
 * respuestas devolvería para siempre el primer token que le tocó.
 */
const inFlight = new Map<string, Promise<Resolution>>()

function sessionFingerprint(request: NextRequest): string {
  return request.cookies
    .getAll()
    .filter((cookie) => cookie.name.startsWith("sb-"))
    .map((cookie) => `${cookie.name}=${cookie.value}`)
    .sort()
    .join("|")
}

// ── Resolución ──────────────────────────────────────────────────────────────

async function resolveSession(request: NextRequest): Promise<Resolution> {
  const cookiesToSet: CookieToSet[] = []
  const supabase = serverClientForRequest(request, cookiesToSet)

  // `getSession()` lee la cookie y **sólo** llama a GoTrue si el access token
  // está vencido o a punto de vencer (`GoTrueClient.js:2341-2370`). De ahí sale
  // gratis la mitad de D19-5: si el middleware ya renovó en esta misma petición,
  // sus cookies frescas viajan en el request y acá no se renueva de nuevo.
  //
  // El `try` no es decorativo: una cookie `sb-*` cuyo cuerpo no sea base64url
  // válido hace **lanzar** a la librería (`Invalid UTF-8 sequence`,
  // `@supabase/ssr/utils/base64url.js`), no devolver `{ error }`. Sin esto, una
  // cookie truncada o pisada convierte este manejador en un 500 en cada carga de
  // página y la app se queda sin token sin forma de recuperarse. Una sesión
  // ilegible es una sesión ausente.
  let session: { access_token?: string; expires_at?: number | null } | null = null
  try {
    const result = await supabase.auth.getSession()
    if (result.error) return { payload: NO_SESSION, cookiesToSet }
    session = result.data.session
  } catch (unreadable) {
    console.warn("[api/auth/token] cookie de sesión ilegible; se responde sin sesión:", unreadable)
    return { payload: NO_SESSION, cookiesToSet: [] }
  }

  if (!session?.access_token) {
    return { payload: NO_SESSION, cookiesToSet }
  }

  return {
    payload: {
      access_token: session.access_token,
      expires_at: session.expires_at ?? null,
      user: userFromAccessToken(session.access_token),
    },
    cookiesToSet,
  }
}

function resolveOnce(request: NextRequest): Promise<Resolution> {
  const key = sessionFingerprint(request)
  const existing = inFlight.get(key)
  if (existing) return existing

  const pending = resolveSession(request).finally(() => {
    inFlight.delete(key)
  })
  inFlight.set(key, pending)
  return pending
}

// ── Respuesta ───────────────────────────────────────────────────────────────

function respond(payload: TokenHandlerPayload, status = 200): NextResponse {
  return withSessionRouteHeaders(NextResponse.json(payload, { status }))
}

export async function GET(request: NextRequest): Promise<NextResponse> {
  if (isCrossSiteRequest(request)) return respond(NO_SESSION, 403)

  if (isIdleSession(request)) {
    await revokeSession(request, "api/auth/token")
    const response = respond(NO_SESSION)
    clearSessionCookies(request, response)
    return response
  }

  const { payload, cookiesToSet } = await resolveOnce(request)

  const response = respond(payload)
  for (const { name, value, options } of cookiesToSet) {
    response.cookies.set(name, value, options)
  }
  return response
}
