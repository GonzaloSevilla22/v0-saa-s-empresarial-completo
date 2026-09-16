/**
 * route-access.ts — qué ruta es pública, cuál es de API y cuál está protegida.
 *
 * auth-hardening-jwt-cookies (D4). Antes de este change el middleware enumeraba
 * a mano 17 prefijos protegidos (`PROTECTED_PREFIXES`). Ese mecanismo produjo
 * F1: 12 de los 29 árboles de `app/(dashboard)` nacieron sin gate y quedaron
 * accesibles anónimamente en producción (medido el 2026-09-16: `/caja`,
 * `/cobranzas`, `/banco`, `/estadisticas`, `/exportaciones`, `/facturacion`,
 * `/planes`, `/rentabilidad`, `/sucursales` → 200; `/finanzas/conciliacion`,
 * `/organizacion/roles`, `/reportes/comparativo` → 200). Agregar los 12 que
 * faltaban habría cerrado el síntoma de hoy dejando intacto el mecanismo: la
 * ruta siguiente vuelve a nacer sin gate.
 *
 * El criterio se invierte: se declara una **allow-list de rutas públicas** y
 * todo lo demás queda **protegido por construcción**. El candado que lo
 * sostiene es `__tests__/lib/protected-routes-coverage.test.ts`, que lee
 * `app/(dashboard)/` del sistema de archivos.
 *
 * Módulo puro a propósito (sin `next/server`, sin `@supabase/ssr`): la decisión
 * se puede testear sin construir un request.
 */

/**
 * Prefijos públicos. Cualquier ruta que empiece con uno de estos —o que sea
 * exactamente uno de ellos— queda fuera del gate de sesión.
 *
 * - `/auth`: deliberado y documentado desde `idle-server-enforcement`. Gatear
 *   `/auth/callback` o `/auth/verify-email` produce un loop de redirect, porque
 *   el destino del propio redirect volvería a entrar por el gate.
 * - `/legal`, `/landing`, `/`: superficie pública del producto.
 * - `/dev-harness`: OQ-8. Vive fuera de `app/(dashboard)` y **ya se auto-gatea**
 *   con `notFound()` cuando `NODE_ENV === "production"` (p. ej.
 *   `app/dev-harness/shell/page.tsx`). Gatearlo rompería los cinco specs de
 *   `e2e/harness/` sin ganar nada, porque en producción no existe.
 * - `/_next`: internos del framework. El matcher del middleware ya excluye
 *   `_next/static` y `_next/image`, pero no el resto del árbol.
 */
export const PUBLIC_PREFIXES = [
  "/auth",
  "/legal",
  "/landing",
  "/dev-harness",
  "/_next",
] as const

/**
 * Rutas públicas exactas (no prefijos): la landing y los archivos de metadatos
 * que el App Router sirve desde la raíz y que el matcher no excluye.
 */
export const PUBLIC_EXACT_PATHS = [
  "/",
  "/manifest.webmanifest",
  "/robots.txt",
  "/sitemap.xml",
] as const

/** Prefijo de las rutas de API del propio dominio. */
const API_PREFIX = "/api"

/**
 * ¿Es una ruta de API del propio dominio?
 *
 * Tercera categoría, ni pública ni protegida-por-redirect: **ninguna** ruta bajo
 * `app/api/` recibe un redirect del middleware. Cada handler decide por su
 * cuenta y responde `401` con cuerpo JSON cuando no hay sesión, como ya hacen
 * los tres existentes (`api/ai/copilot`, `api/billing/cancel`,
 * `api/billing/preferences`). Redirigirlas devolvería HTML donde el consumidor
 * espera JSON — y dejaría inutilizable el manejador que entrega el access token
 * (Parte C de este mismo change).
 */
export function isApiPath(pathname: string): boolean {
  return pathname === API_PREFIX || pathname.startsWith(`${API_PREFIX}/`)
}

/** ¿Está la ruta en la allow-list pública? */
export function isPublicPath(pathname: string): boolean {
  if ((PUBLIC_EXACT_PATHS as readonly string[]).includes(pathname)) return true
  return (PUBLIC_PREFIXES as readonly string[]).some(
    (prefix) => pathname === prefix || pathname.startsWith(`${prefix}/`),
  )
}

/**
 * ¿Exige sesión esta ruta? Protegido por defecto: todo lo que no sea público ni
 * una ruta de API.
 */
export function isProtectedPath(pathname: string): boolean {
  if (isApiPath(pathname)) return false
  return !isPublicPath(pathname)
}
