/**
 * Banco de pruebas del middleware de sesión (`lib/supabase/middleware.ts`).
 *
 * auth-hardening-jwt-cookies, Parte B. La auditoría del 2026-09-14 (§10) dejó
 * constancia de que **ningún** test del repo importaba `updateSession`: los
 * cuatro que tocaban ese archivo tomaban sólo exports puros. Todo lo que el
 * middleware decide —gate por sesión, copia de cookies rotadas en los redirects
 * no destructivos, purga, corte por inactividad— quedaba sin fijar.
 *
 * Este módulo NO es un archivo de test (no matchea `*.test.ts`): expone el
 * doble de `@supabase/ssr` y los helpers de request/respuesta que consumen los
 * archivos de test de la Parte B. El doble se configura desde `harness`, que el
 * test resetea en cada caso.
 */
import { NextRequest } from "next/server"

export interface HarnessUser {
  id: string
  email?: string
  email_confirmed_at?: string | null
}

export interface RotatedCookie {
  name: string
  value: string
  options?: Record<string, unknown>
}

interface HarnessState {
  /** Usuario que devuelve `auth.getUser()`. */
  user: HarnessUser | null
  /** Error que devuelve `auth.getUser()` (p. ej. "Refresh Token Not Found"). */
  authError: { message: string } | null
  /** Rol devuelto por el SELECT de `profiles` (null ⇒ fila ausente). */
  profileRole: string | null
  /**
   * Cookies que el servidor "rota" durante `getUser()`. Se escriben a través
   * del `setAll` real del middleware, igual que lo haría `@supabase/ssr` al
   * renovar la sesión.
   */
  cookiesToRotate: RotatedCookie[]
  /** Opciones con las que se llamó a `auth.signOut()`, en orden. */
  signOutCalls: unknown[]
  /** Si es true, `auth.signOut()` **lanza** (proveedor caído / red rota). */
  signOutRejects: boolean
  /**
   * Si es true, `auth.signOut()` **no lanza** y devuelve `{ error }`.
   *
   * Es el modo de falla real de auth-js y el que faltaba en este banco: `_signOut`
   * se come 401/403/404 y **devuelve** el error para el resto (p. ej. un 5xx de
   * GoTrue). Un `try/catch` alrededor no lo ve (MINOR 3 de la revisión
   * adversarial).
   */
  signOutReturnsError: boolean
  /** Orden de eventos observados ("signOut", "getUser"), para aserciones de secuencia. */
  events: string[]
}

export const harness: HarnessState = {
  user: null,
  authError: null,
  profileRole: null,
  cookiesToRotate: [],
  signOutCalls: [],
  signOutRejects: false,
  signOutReturnsError: false,
  events: [],
}

export function resetHarness(): void {
  harness.user = null
  harness.authError = null
  harness.profileRole = null
  harness.cookiesToRotate = []
  harness.signOutCalls = []
  harness.signOutRejects = false
  harness.signOutReturnsError = false
  harness.events = []
}

type CookiesToSet = { name: string; value: string; options?: Record<string, unknown> }[]

interface ServerClientOptions {
  cookies: {
    getAll: () => { name: string; value: string }[]
    setAll: (cookiesToSet: CookiesToSet) => void
  }
  cookieOptions?: Record<string, unknown>
}

/** Última `cookieOptions` con la que se construyó el cliente (task 15.3b/15.2). */
export let lastCookieOptions: Record<string, unknown> | undefined

/** Doble de `createServerClient` de `@supabase/ssr`. */
export function createServerClientMock(
  _url: string,
  _key: string,
  options: ServerClientOptions,
) {
  lastCookieOptions = options.cookieOptions
  return {
    auth: {
      async getUser() {
        harness.events.push("getUser")
        if (harness.cookiesToRotate.length > 0) {
          options.cookies.setAll(
            harness.cookiesToRotate.map((c) => ({
              name: c.name,
              value: c.value,
              options: c.options ?? { path: "/" },
            })),
          )
        }
        return { data: { user: harness.user }, error: harness.authError }
      },
      async signOut(signOutOptions?: unknown) {
        harness.events.push("signOut")
        harness.signOutCalls.push(signOutOptions)
        if (harness.signOutRejects) {
          throw new Error("GoTrue no responde")
        }
        if (harness.signOutReturnsError) {
          // Forma real de auth-js: devuelve el error, no lo lanza.
          return { error: { message: "AuthApiError: 503 Service Unavailable", status: 503 } }
        }
        return { error: null }
      },
    },
    from(_table: string) {
      return {
        select(_columns: string) {
          return {
            eq(_column: string, _value: unknown) {
              return {
                async single() {
                  return {
                    data: harness.profileRole === null ? null : { role: harness.profileRole },
                    error: null,
                  }
                },
              }
            },
          }
        },
      }
    },
  }
}

const ORIGIN = "https://app.test"

/** Construye un `NextRequest` con las cookies indicadas. */
export function buildRequest(
  pathname: string,
  cookies: Record<string, string> = {},
): NextRequest {
  const request = new NextRequest(new URL(pathname, ORIGIN))
  for (const [name, value] of Object.entries(cookies)) {
    request.cookies.set(name, value)
  }
  return request
}

/** Las líneas `Set-Cookie` realmente emitidas por la respuesta. */
export function setCookieLines(response: Response): string[] {
  return response.headers.getSetCookie()
}

/** Líneas `Set-Cookie` de cookies de sesión de Supabase (`sb-*`). */
export function sessionCookieLines(response: Response): string[] {
  return setCookieLines(response).filter((line) => line.startsWith("sb-"))
}

/**
 * ¿Esa línea `Set-Cookie` es un **borrado**? Un borrado lleva valor vacío y una
 * expiración en el pasado (`Max-Age=0` o `Expires=Thu, 01 Jan 1970 …`).
 */
export function isCookieDeletion(setCookieLine: string): boolean {
  const [pair] = setCookieLine.split(";")
  const value = pair.slice(pair.indexOf("=") + 1)
  const expiresInThePast =
    /max-age=0(\s|;|$)/i.test(setCookieLine) ||
    /expires=thu, 01 jan 1970/i.test(setCookieLine)
  return value === "" && expiresInThePast
}

/** ¿Es una respuesta de redirección? */
export function isRedirect(response: Response): boolean {
  return response.status >= 300 && response.status < 400
}

/** Destino de un redirect (header `location`). */
export function redirectTarget(response: Response): string | null {
  return response.headers.get("location")
}
