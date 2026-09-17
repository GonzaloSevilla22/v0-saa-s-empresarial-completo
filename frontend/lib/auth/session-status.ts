/**
 * session-status.ts — el estado de verificación del email, para el navegador.
 *
 * auth-hardening-jwt-cookies (Parte C, D18). Con la sesión en cookies `HttpOnly`
 * el navegador no puede mirar `email_confirmed_at`, y con `accessToken`
 * configurado tampoco puede preguntárselo a `supabase.auth`. Este módulo es el
 * único cliente de `GET /api/auth/status`.
 *
 * El tipo vive acá —y el manejador de ruta lo importa de acá— para que el
 * contrato tenga una sola definición y no dos que se puedan desalinear.
 */

export interface AuthStatus {
  email: string | null
  email_confirmed_at: string | null
}

const UNKNOWN: AuthStatus = { email: null, email_confirmed_at: null }

/** Ruta del endpoint. Un solo literal. */
export const AUTH_STATUS_PATH = "/api/auth/status"

/**
 * Consulta el estado de verificación. **Nunca lanza**: la pantalla que la usa
 * sondea cada 4 s y un fallo de red no puede dejarla en un estado de error — se
 * sigue esperando, que es exactamente lo que el usuario está haciendo.
 */
export async function fetchAuthStatus(): Promise<AuthStatus> {
  try {
    const response = await fetch(AUTH_STATUS_PATH, {
      // Sin credenciales del propio origen el endpoint no ve la cookie
      // `HttpOnly` y la verificación nunca se detecta.
      credentials: "same-origin",
      cache: "no-store",
      headers: { Accept: "application/json" },
    })
    if (!response.ok) return UNKNOWN
    const body = (await response.json()) as Partial<AuthStatus> | null
    return {
      email: typeof body?.email === "string" ? body.email : null,
      email_confirmed_at:
        typeof body?.email_confirmed_at === "string" ? body.email_confirmed_at : null,
    }
  } catch {
    return UNKNOWN
  }
}
