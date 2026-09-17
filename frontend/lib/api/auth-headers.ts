/**
 * auth-headers.ts — la ÚNICA implementación de "armar los encabezados de
 * autenticación" para los transportes del navegador hacia el backend propio.
 *
 * auth-hardening-jwt-cookies (D21 + D7). Antes de este change ocho sitios lo
 * armaban por su cuenta, con tres consecuencias:
 *
 *  1. Tres de ellos mandaban `Authorization: Bearer ` **vacío** cuando no había
 *     sesión, en vez de omitir el encabezado
 *     (`components/ventas/sale-receipt-button.tsx:132-140`,
 *     `app/(dashboard)/admin/pagos/page.tsx:146-152`).
 *  2. `lib/api/python-client.ts:54` mergeaba `extraHeaders` **después** de los
 *     de auth, así que un caller podía sobrescribir `Authorization`.
 *  3. El tratamiento del 401 divergía: sólo `python-client` lo miraba, y su
 *     mensaje recomendaba "recargá la página" — un consejo que delegaba la
 *     renovación en un redirect del middleware que en las 12 rutas de F1
 *     nunca ocurría.
 *
 * Los encabezados de auth se aplican **últimos**: el orden de merge deja de ser
 * una decisión de cada call site.
 *
 * PARTE C (task 19.8f): la consulta ya no pasa por el cliente de navegador. El
 * token sale de `lib/auth/access-token-store.ts`, que lo tiene en memoria y lo
 * obtiene del token handler (`GET /api/auth/token`, D1). Era el único punto que
 * había que cambiar, y por eso la Parte B lo centralizó primero: con los ocho
 * transportes armando su propio Bearer, este cambio habría sido ocho cambios.
 */
import { resolveAccessToken } from "@/lib/auth/access-token-store"

/**
 * Seam de navegación.
 *
 * `window.location.assign` no es espiable en jsdom (la navegación no está
 * implementada y la propiedad no es configurable), así que la navegación real
 * pasa por este objeto para que los tests puedan observarla sin stubear
 * `window.location`.
 */
export const sessionNavigation = {
  assign(url: string): void {
    if (typeof window === "undefined") return
    window.location.assign(url)
  },
}

/**
 * Resultado de consultar el estado de sesión.
 *
 * Revisión adversarial (MINOR 4): hasta esta ronda la consulta devolvía
 * `string | null` y **conflaba** dos estados distintos — "no hay sesión" y "no
 * pude averiguarlo". El requirement dice *"consultando el estado de sesión y,
 * **cuando no exista sesión**, SHALL navegar"*: un fallo transitorio de la
 * consulta (refresh token perfectamente válido, almacenamiento bloqueado) no es
 * "no existe sesión", y producía una navegación dura que tira el estado de la
 * pantalla en curso — un formulario de venta a medio cargar.
 */
export type SessionProbe =
  | { status: "active"; token: string }
  | { status: "absent" }
  | { status: "unknown" }

/**
 * Consulta el estado de sesión. Nunca lanza.
 *
 * Los tres estados son los **mismos** que resuelve el store, que ya distingue
 * "el servidor dijo que no hay sesión" de "no pude averiguarlo": la traducción
 * que antes hacía un `try/catch` acá desapareció.
 *
 * @param force ignora el token cacheado. Es el camino del 401 y sólo ése: el 401
 *   es la evidencia de que lo cacheado ya no sirve. Armar los encabezados de una
 *   llamada cualquiera **no** fuerza nada, o cada llamada al backend propio
 *   costaría un `GET /api/auth/token` extra.
 */
async function probeSession(force = false): Promise<SessionProbe> {
  const resolution = await resolveAccessToken({ force })
  if (resolution.status === "active") {
    // Un token vacío no es un token: el encabezado se omite igual que sin sesión
    // (era uno de los tres Bearer vacíos que D21 vino a cerrar).
    return resolution.token ? { status: "active", token: resolution.token } : { status: "absent" }
  }
  return { status: resolution.status }
}

/**
 * Encabezados para una llamada al backend propio.
 *
 * @param extraHeaders encabezados del caller (`Content-Type`,
 *   `Idempotency-Key`, …). Los de autenticación se aplican **después**, de modo
 *   que un caller no pueda sobrescribir `Authorization`.
 */
export async function getAuthHeaders(
  extraHeaders?: Record<string, string>,
): Promise<Record<string, string>> {
  const probe = await probeSession()
  return {
    ...(extraHeaders ?? {}),
    ...(probe.status === "active" ? { Authorization: `Bearer ${probe.token}` } : {}),
  }
}

/** Prefijo del esquema de autorización. El formato vive sólo en este módulo. */
const BEARER_PREFIX = "Bearer "

/**
 * Token que viaja en unos encabezados ya armados, o `null`.
 *
 * Lo consume `python-client` para poder comparar el token que **envió** con el
 * que la consulta devuelve después del 401: sin esa comparación no se puede
 * distinguir "el token venció mientras la pantalla estaba abierta" —el caso más
 * frecuente, que `getSession()` resuelve auto-refrescando— de un problema real
 * de autorización.
 */
export function tokenFromHeaders(headers: Record<string, string>): string | null {
  const header = headers.Authorization
  if (!header?.startsWith(BEARER_PREFIX)) return null
  return header.slice(BEARER_PREFIX.length) || null
}

/**
 * Qué se hizo con un 401 del backend propio.
 *
 * - `navigated`: no había sesión → se navegó al login (D7).
 * - `session-renewed`: hay sesión y el token **cambió** respecto del que se
 *   envió → el 401 fue por frescura y ya se resolvió; reintentar es del usuario,
 *   no del transporte (reintentar automáticamente una mutación no es seguro).
 * - `session-active`: hay sesión con el mismo token → el 401 es de autorización.
 * - `session-unknown`: no se pudo determinar el estado → NO se navega.
 */
export type UnauthorizedOutcome =
  | "navigated"
  | "session-renewed"
  | "session-active"
  | "session-unknown"

/**
 * Reacción compartida a un 401 del backend propio (D7).
 *
 * @param sentToken token que el caller envió en la llamada que recibió el 401,
 *   si lo tiene a mano. Sin él no se puede reconocer una renovación.
 */
export async function handleUnauthorized(
  sentToken?: string | null,
): Promise<UnauthorizedOutcome> {
  // `force`: hasta la Parte C esto lo daba gratis el auto-refresh de
  // `getSession()`. Con el token en memoria y cacheado por su TTL, preguntar sin
  // forzar devolvería el MISMO token que acaba de recibir el 401 — y el
  // transporte informaría un problema de permisos por un problema de frescura.
  const probe = await probeSession(true)

  if (probe.status === "unknown") return "session-unknown"
  if (probe.status === "active") {
    return sentToken && probe.token !== sentToken ? "session-renewed" : "session-active"
  }

  const current =
    typeof window === "undefined"
      ? "/dashboard"
      : `${window.location.pathname}${window.location.search}`

  sessionNavigation.assign(
    `/auth/login?reason=expired&next=${encodeURIComponent(current)}`,
  )
  return "navigated"
}

/**
 * Idioma compartido de los `fetch` a mano: *"si el 401 ya se manejó navegando,
 * cortar acá"*.
 *
 * Revisión adversarial (MINOR 2 de seguridad). Los dos call sites que no pasan
 * por un cliente hacían `if (res.status === 401) { await handleUnauthorized() }`
 * y en la línea siguiente `if (!res.ok) throw …`. `window.location.assign()` es
 * asíncrono, así que el usuario veía el cartel de error mientras la navegación
 * salía. El idioma vive acá en vez de copiado en cada call site.
 *
 * @returns `true` si el 401 se resolvió navegando (el caller debe cortar).
 */
export async function redirectedOnUnauthorized(
  response: Response,
  sentToken?: string | null,
): Promise<boolean> {
  if (response.status !== 401) return false
  return (await handleUnauthorized(sentToken)) === "navigated"
}
