/**
 * route-session.ts — lo que comparten los manejadores de ruta que leen la sesión.
 *
 * auth-hardening-jwt-cookies (Parte C, D1 + D18 + D19). Después de la Parte C hay
 * dos endpoints que abren la cookie `HttpOnly` desde el servidor y le contestan
 * al navegador: `GET /api/auth/token` (el access token efímero) y
 * `GET /api/auth/status` (el estado de verificación del email). Las garantías que
 * D19 vuelve normativas —no cacheable, sin CORS, sólo same-origin, y **una sola**
 * decisión de inactividad en el servidor— tienen que ser las mismas en los dos.
 *
 * Por eso viven acá y no copiadas en cada `route.ts`: dos implementaciones de "qué
 * es una sesión ociosa" o de "qué encabezados lleva una respuesta con credencial"
 * divergen, y cuando divergen el que se relaja no da ningún error — simplemente
 * deja de proteger. Es la regla de reutilización del proyecto aplicada al sitio
 * donde más cuesta pagarla.
 *
 * Módulo de servidor: importa `next/server` y `@supabase/ssr`. No lo importa
 * ningún código de navegador.
 */
import { createServerClient } from "@supabase/ssr"
import type { NextRequest, NextResponse } from "next/server"
import { evaluateIdle } from "@/lib/auth/idle-server"
import { COOKIE_KEYS } from "@/lib/cookies"
import { authCookieOptions } from "@/lib/supabase/cookie-options"

/** Prefijo de las cookies de sesión de Supabase. */
export const SESSION_COOKIE_PREFIX = "sb-"

/** Cookie que la librería quiere escribir durante la petición. */
export type CookieToSet = { name: string; value: string; options?: Record<string, unknown> }

// ── Transporte ──────────────────────────────────────────────────────────────

/**
 * Encabezados obligatorios de una respuesta que depende de la sesión (D19-1/2).
 *
 * `no-store` + `Vary: Cookie` para que ningún intermediario —empezando por el CDN
 * de Vercel— pueda servirle a un usuario la respuesta de otro. `nosniff` es la
 * mitad que mata el `<script src>` cross-site sobre un cuerpo JSON: el middleware
 * ya lo pone en todas las respuestas, pero una garantía normativa no puede
 * depender de otro archivo.
 *
 * Y lo que **no** hay: ningún `Access-Control-Allow-Origin`, bajo ninguna
 * configuración. Estos módulos tampoco exportan `OPTIONS` — sin preflight no hay
 * CORS que negociar.
 */
export function withSessionRouteHeaders(response: NextResponse): NextResponse {
  response.headers.set("Cache-Control", "no-store, no-cache, must-revalidate, private")
  response.headers.set("Pragma", "no-cache")
  response.headers.set("Vary", "Cookie")
  response.headers.set("X-Content-Type-Options", "nosniff")
  return response
}

/**
 * ¿Viene de otro sitio? (D19-3)
 *
 * `Sec-Fetch-Site` lo pone el navegador y no es falsificable desde JavaScript.
 * **Ausente ⇒ se permite**: hay clientes que no lo mandan y negarlo dejaría sin
 * sesión a un navegador viejo legítimo. La defensa de fondo sigue siendo
 * `SameSite=Lax` (que no manda la cookie en subrecursos cross-site) más la
 * ausencia total de CORS.
 */
export function isCrossSiteRequest(request: NextRequest): boolean {
  const fetchSite = request.headers.get("sec-fetch-site")
  return fetchSite !== null && fetchSite !== "same-origin"
}

// ── Cookies de sesión ───────────────────────────────────────────────────────

export function hasSessionCookie(request: NextRequest): boolean {
  return request.cookies.getAll().some((cookie) => cookie.name.startsWith(SESSION_COOKIE_PREFIX))
}

/**
 * Borra las cookies de sesión y las de experiencia asociadas, con la misma
 * paridad que la rama de idle del middleware y que `clearAuthUxCookies()`: la
 * marca de actividad sobreviviente es la que producía el bounce del primer
 * re-login después de un corte por inactividad (D6).
 */
export function clearSessionCookies(request: NextRequest, response: NextResponse): void {
  for (const cookie of request.cookies.getAll()) {
    if (cookie.name.startsWith(SESSION_COOKIE_PREFIX)) response.cookies.delete(cookie.name)
  }
  response.cookies.delete(COOKIE_KEYS.LAST_ACTIVITY)
  response.cookies.delete(COOKIE_KEYS.TENANT)
}

// ── Cliente de servidor sobre las cookies de la petición ────────────────────

/**
 * Cliente de servidor que lee las cookies de **esta** petición y acumula en
 * `cookiesToSet` las que la librería quiera escribir. No se puede construir la
 * respuesta todavía porque el cuerpo depende del resultado, así que las cookies
 * se aplican al final — o se descartan, cuando la rama existe para quitar la
 * sesión y no para reponerla.
 */
export function serverClientForRequest(request: NextRequest, cookiesToSet: CookieToSet[]) {
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      // Los atributos salen de la definición compartida: estos manejadores
      // reescriben las mismas cookies que el middleware.
      cookieOptions: authCookieOptions(),
      cookies: {
        getAll() {
          return request.cookies.getAll().map(({ name, value }) => ({ name, value }))
        },
        setAll(pending) {
          cookiesToSet.push(...pending)
        },
      },
    },
  )
}

// ── Inactividad ─────────────────────────────────────────────────────────────

/**
 * ¿Hay que cortar por inactividad? (D19-4)
 *
 * Usa el **mismo** `evaluateIdle` que el middleware, con el mismo umbral: no
 * existe un segundo criterio de "sesión ociosa" en el servidor. El middleware no
 * idle-gatea `/api/**` a propósito (`lib/auth/route-access.ts`), así que sin esto
 * cada uno de estos endpoints sería un camino de refresh server-side **no
 * gateado** que mantiene viva indefinidamente la sesión de un usuario ausente
 * desde una pestaña de fondo — una regresión del control de idle introducida por
 * el change que viene a reforzarlo.
 *
 * Una cookie de actividad **ausente** no corta (`evaluateIdle` ⇒ "seed",
 * Decision 6 de `idle-server-enforcement`): tratar la ausencia como inactividad
 * cerraría la sesión de la primera carga de página y la del usuario recién
 * registrado, que llega sin marca porque el temporizador vive dentro del
 * dashboard.
 */
export function isIdleSession(request: NextRequest): boolean {
  if (!hasSessionCookie(request)) return false
  const lastActivity = request.cookies.get(COOKIE_KEYS.LAST_ACTIVITY)?.value
  return evaluateIdle(lastActivity, Date.now()).action === "logout"
}

/**
 * Revoca la sesión contra el proveedor antes de borrarla.
 *
 * Mismo criterio que la rama de idle del middleware (D6): `scope: 'local'` —el
 * corte de un dispositivo no cierra los demás— y el cierre **no** queda
 * condicionado a que el proveedor conteste, porque una caída de GoTrue
 * desactivaría el corte por inactividad entero.
 *
 * Las cookies que la librería quiera escribir durante el cierre se **descartan**
 * a propósito: con el access token vencido, `signOut()` renueva primero para
 * tener un token con el que revocar, y esa rotación no debe llegar nunca a la
 * respuesta — sería el manejador reponiéndole la sesión al navegador justo en la
 * rama cuyo trabajo es quitársela.
 */
export async function revokeSession(request: NextRequest, source: string): Promise<void> {
  const discarded: CookieToSet[] = []
  const supabase = serverClientForRequest(request, discarded)
  try {
    const { error } = await supabase.auth.signOut({ scope: "local" })
    if (error) {
      // auth-js **no lanza** en el caso normal: se come 401/403/404 y **devuelve**
      // el error para el resto (p. ej. un 5xx). Sin destructurarlo, la sesión
      // quedaba viva en el emisor sin una sola línea de log.
      console.warn(`[${source}] idle signOut returned an error (clearing cookies anyway):`, error.message)
    }
  } catch (signOutError) {
    console.warn(`[${source}] idle signOut failed (clearing cookies anyway):`, signOutError)
  }
}
