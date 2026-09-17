/**
 * access-token-store.ts — el access token del navegador, sólo en memoria.
 *
 * auth-hardening-jwt-cookies (Parte C, D1). Con la sesión en cookies `HttpOnly`,
 * el navegador ya no puede leerla: pide su access token a `GET /api/auth/token` y
 * lo guarda **acá**, en el estado de este módulo. En ninguna cookie, ningún
 * `localStorage`, ningún `sessionStorage`. Escribirlo en cualquiera de los tres
 * anularía el motivo por el que existe el manejador: volvería a haber una
 * credencial legible por cualquier script de la página.
 *
 * Es la fuente del callback que consume `lib/supabase/client.ts`:
 *
 *     createClient(url, anonKey, { accessToken: () => getAccessToken() })
 *
 * y también el "contexto de sesión" de los módulos que no son React y necesitan
 * la identidad (`getSessionUser()`), donde antes hacían `supabase.auth.getUser()`.
 *
 * ── Tres reglas que no son negociables ──────────────────────────────────────
 *
 * 1. **`getAccessToken()` resuelve, nunca lanza.** Un visitante anónimo de una
 *    página pública también dispara el callback. Si lanza, la llamada falla; si
 *    resuelve vacío, `fetchWithAuth` cae a la anon key
 *    (`supabase-js/index.mjs:112`) y la página pública sigue renderizando.
 * 2. **Un solo pedido en vuelo.** Cada carga de página dispara varias llamadas a
 *    PostgREST a la vez y todas pasan por el callback.
 * 3. **"No hay sesión" no se reintenta dentro de la misma carga; "no pude
 *    averiguarlo" sí.** Son estados distintos y confundirlos cuesta caro en los
 *    dos sentidos: reintentar el primero es una tormenta de pedidos desde cada
 *    página pública; cachear el segundo deja la app anónima por un hipo de red.
 */
// ── Contrato ────────────────────────────────────────────────────────────────

/** Ruta del *token handler*. Un solo literal, igual que `AUTH_STATUS_PATH`. */
export const AUTH_TOKEN_PATH = "/api/auth/token"

export interface SessionUser {
  id: string
  email: string | null
  /**
   * Nombre de `user_metadata`, tal como lo entrega el manejador. Existe por la
   * cascada de nombre a mostrar del contexto de sesión (`profiles.name ||
   * user_metadata.name || prefijo del email`): sin él, el usuario cuyo perfil
   * quedó sin nombre pasaría a verse como el prefijo de su email sin que nadie lo
   * haya decidido.
   */
  name: string | null
}

export type AccessTokenResolution =
  | { status: "active"; token: string; expiresAt: number | null; user: SessionUser | null }
  /** El servidor contestó que no hay sesión. */
  | { status: "absent" }
  /** No se pudo averiguar (red caída, respuesta rara). NO es "no hay sesión". */
  | { status: "unknown" }

/**
 * Margen con el que un token se considera "por vencer".
 *
 * 60 s: un token que vence en menos de eso puede vencer **en vuelo**, entre que
 * se lee de memoria y que llega al servidor que lo verifica.
 *
 * ⚠️ **No es un número libre: tiene que ser MENOR que el margen del servidor.**
 * Revisión adversarial de la Parte C. Del otro lado, `getSession()` sólo renueva
 * cuando al token le faltan menos de `EXPIRY_MARGIN_MS = AUTO_REFRESH_TICK_THRESHOLD
 * × AUTO_REFRESH_TICK_DURATION_MS = 3 × 30 s = 90 s`
 * (`@supabase/auth-js/dist/main/lib/constants.js:6,9,13`). Con 60 < 90, cuando el
 * navegador pide el token el servidor **siempre** lo renueva y vuelve uno fresco.
 * Si este margen subiera por encima de 90 s, el manejador devolvería el **mismo**
 * token —para él todavía no vence—, el navegador lo seguiría viendo por vencer y
 * agendaría la renovación con `delay = 0`: tormenta de pedidos contra el endpoint y
 * contra los rate limits por IP de GoTrue, que D20 acaba de volver compartidos
 * entre los 38 tenants. El candado que lo fija:
 * `__tests__/lib/access-token-store-renewal-margin.test.ts`.
 */
export const RENEWAL_MARGIN_MS = 60_000

// ── Estado de módulo ────────────────────────────────────────────────────────

interface Snapshot {
  token: string
  /** Segundos epoch, tal como los devuelve el manejador. */
  expiresAt: number | null
  user: SessionUser | null
}

let snapshot: Snapshot | null = null
/** El servidor ya dijo, en esta carga de página, que no hay sesión. */
let absent = false
let inFlight: Promise<AccessTokenResolution> | null = null
let renewalTimer: ReturnType<typeof setTimeout> | null = null

const listeners = new Set<(token: string | null) => void>()

function isStale(current: Snapshot): boolean {
  if (current.expiresAt === null) return false
  return current.expiresAt * 1000 - Date.now() <= RENEWAL_MARGIN_MS
}

function notify(token: string | null): void {
  for (const listener of listeners) {
    try {
      listener(token)
    } catch (listenerError) {
      // Un consumidor roto no puede cancelar la renovación de los demás: el
      // primero de la lista es el que vuelve a enganchar Realtime.
      console.warn("[access-token-store] un suscriptor falló al recibir el token:", listenerError)
    }
  }
}

function cancelRenewal(): void {
  if (renewalTimer !== null) {
    clearTimeout(renewalTimer)
    renewalTimer = null
  }
}

/**
 * Agenda la renovación **antes** del vencimiento.
 *
 * Sin esto, una pestaña abierta y quieta se queda con un token muerto hasta que
 * el usuario vuelva a interactuar — y lo primero que hace al volver es recibir un
 * 401. El temporizador no mantiene viva la sesión de un ausente: el manejador
 * aplica el corte por inactividad del lado del servidor (D19-4).
 */
function scheduleRenewal(current: Snapshot): void {
  cancelRenewal()
  if (current.expiresAt === null || typeof window === "undefined") return

  const delay = Math.max(0, current.expiresAt * 1000 - Date.now() - RENEWAL_MARGIN_MS)
  renewalTimer = setTimeout(() => {
    renewalTimer = null
    void refreshAccessToken()
  }, delay)
}

// ── Lectura del manejador ───────────────────────────────────────────────────

function parseUser(raw: unknown): SessionUser | null {
  if (!raw || typeof raw !== "object") return null
  const candidate = raw as Record<string, unknown>
  if (typeof candidate.id !== "string" || candidate.id === "") return null
  return {
    id: candidate.id,
    email: typeof candidate.email === "string" ? candidate.email : null,
    name: typeof candidate.name === "string" && candidate.name !== "" ? candidate.name : null,
  }
}

async function fetchFromHandler(): Promise<AccessTokenResolution> {
  try {
    const response = await fetch(AUTH_TOKEN_PATH, {
      // Sin credenciales del propio origen el manejador no ve la cookie
      // `HttpOnly` y no hay token que entregar.
      credentials: "same-origin",
      cache: "no-store",
      headers: { Accept: "application/json" },
    })
    if (!response.ok) return { status: "unknown" }

    const body = (await response.json()) as Record<string, unknown> | null
    const token = body?.access_token
    if (typeof token !== "string" || token === "") return { status: "absent" }

    const expiresAt = typeof body?.expires_at === "number" ? body.expires_at : null
    return { status: "active", token, expiresAt, user: parseUser(body?.user) }
  } catch {
    // Red caída, cuerpo ilegible, petición abortada: no se sabe. NO es "no hay
    // sesión" — ver la regla 3 del encabezado.
    return { status: "unknown" }
  }
}

async function loadOnce(): Promise<AccessTokenResolution> {
  if (inFlight) return inFlight

  const pending = (async (): Promise<AccessTokenResolution> => {
    const resolution = await fetchFromHandler()

    if (resolution.status === "active") {
      snapshot = {
        token: resolution.token,
        expiresAt: resolution.expiresAt,
        user: resolution.user,
      }
      absent = false
      scheduleRenewal(snapshot)
      notify(resolution.token)
    } else if (resolution.status === "absent") {
      snapshot = null
      absent = true
      cancelRenewal()
      notify(null)
    }
    // "unknown": no se toca el estado. Un hipo de red no borra un token válido ni
    // fija un "no hay sesión" que después no se reintenta.

    return resolution
  })().finally(() => {
    inFlight = null
  })

  inFlight = pending
  return pending
}

// ── API pública ─────────────────────────────────────────────────────────────

/**
 * Estado de la sesión con su token, distinguiendo los tres casos.
 *
 * Lo consume `lib/api/auth-headers.ts`, que necesita separar "no hay sesión"
 * (navegar al login) de "no pude averiguarlo" (no navegar).
 *
 * @param options.force ignora lo que haya en memoria. Es el camino del 401: el
 *   401 es la evidencia de que lo cacheado ya no sirve.
 */
export async function resolveAccessToken(
  options: { force?: boolean } = {},
): Promise<AccessTokenResolution> {
  if (typeof window === "undefined") {
    // Render en el servidor: no hay a quién pedirle una ruta relativa, y el token
    // de un render no debe quedar en memoria de un proceso compartido.
    return { status: "unknown" }
  }

  if (options.force) {
    absent = false
    return loadOnce()
  }

  if (snapshot && !isStale(snapshot)) {
    return {
      status: "active",
      token: snapshot.token,
      expiresAt: snapshot.expiresAt,
      user: snapshot.user,
    }
  }
  if (absent) return { status: "absent" }

  return loadOnce()
}

/**
 * El token para el callback `accessToken` de supabase-js. **Nunca lanza.**
 *
 * Devolver `null` es un estado legítimo: `fetchWithAuth` cae a la anon key y la
 * página pública sigue funcionando.
 */
export async function getAccessToken(): Promise<string | null> {
  const resolution = await resolveAccessToken()
  return resolution.status === "active" ? resolution.token : null
}

/**
 * Renovación forzada. La piden el temporizador, el retorno a la pestaña y el
 * transporte tras un 401 — y también hay que llamarla después de iniciar sesión
 * por una acción de servidor, para invalidar un "no hay sesión" cacheado.
 */
export async function refreshAccessToken(): Promise<AccessTokenResolution> {
  return resolveAccessToken({ force: true })
}

/**
 * Identidad de la sesión, para los módulos que no son React.
 *
 * Es el reemplazo de `supabase.auth.getUser()` en `lib/services/*`,
 * `lib/supabase/services.ts` y `lib/ai/*`. Viene del mismo `user` que acompaña al
 * token, así que no cuesta una llamada extra. En componentes y hooks, la
 * identidad sale de `useAuth()`, que además trae perfil, cuenta y plan.
 */
export async function getSessionUser(): Promise<SessionUser | null> {
  const resolution = await resolveAccessToken()
  return resolution.status === "active" ? resolution.user : null
}

/**
 * Olvida el token. La llaman los caminos de cierre de sesión: dejarlo en memoria
 * después de un `signOut` deja a la pestaña operando con una credencial que el
 * servidor ya revocó, hasta que venza.
 */
export function clearAccessToken(): void {
  snapshot = null
  absent = true
  cancelRenewal()
}

/**
 * Se entera cada vez que el token cambia (o se pierde).
 *
 * Existe por Realtime: el canal queda **pinneado** al token con que se construyó
 * el cliente y hay que llamar `realtime.setAuth()` **sin argumentos** para
 * despinnearlo (`RealtimeClient.js:330-339`). Ese cableado vive en
 * `lib/supabase/client.ts`, una sola vez, no en cada hook que abre un canal.
 *
 * @returns función de baja.
 */
export function subscribeToAccessToken(listener: (token: string | null) => void): () => void {
  listeners.add(listener)
  return () => {
    listeners.delete(listener)
  }
}

// ── Retorno a la pestaña ────────────────────────────────────────────────────

if (typeof document !== "undefined") {
  document.addEventListener("visibilitychange", () => {
    if (document.visibilityState === "hidden") return
    // Sólo si hay algo que renovar **y** hace falta: los temporizadores de una
    // pestaña de fondo se estrangulan, así que volver a ella es el momento de
    // revisar — pero pedir el token en cada cambio de pestaña sería un pedido de
    // más en cada página pública de cada visitante anónimo.
    if (snapshot && isStale(snapshot)) void refreshAccessToken()
  })
}
