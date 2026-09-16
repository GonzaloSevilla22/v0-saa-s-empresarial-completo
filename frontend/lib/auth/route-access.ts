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
 * Ese mismo archivo trae el **candado simétrico** (MAJOR 1 de la revisión
 * adversarial): con protección por defecto, el modo de falla inverso es que una
 * superficie pública nueva nazca **detrás del login** para todo visitante
 * anónimo. Así que también lee los árboles de `app/` que no son el área
 * autenticada y exige que estén declarados acá.
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
 * Extensiones de archivo estático que la allow-list reconoce como públicas.
 *
 * Revisión adversarial (MINOR 2). D4 enumera la allow-list como "`/`, `/auth/*`,
 * `/legal/*`, landing, **assets**", pero acá no había ninguna regla de assets:
 * lo único que salvaba a `public/` era el matcher del middleware, que excluye
 * **sólo** `svg|png|jpg|jpeg|gif|webp`. Los archivos de `public/` de hoy son
 * todos de esas extensiones, así que no había regresión viva — pero el primer
 * `.woff2`, `.glb`, `.ktx2`, `.hdr`, `.wasm` o `.pdf` que alguien pusiera ahí
 * quedaba con un 307 al login para cualquier visitante anónimo, y `public/3d/`
 * es justo donde caería un decoder de R3F/drei.
 *
 * Es un conjunto **cerrado**, no "cualquier segmento con punto": con la regla
 * abierta, un identificador con punto en una ruta dinámica volvería pública esa
 * ruta. Con el conjunto cerrado, el peor caso es una ruta dinámica cuyo
 * identificador termine en una de estas extensiones — un identificador que no
 * corresponde a ninguna fila real, así que la pantalla no muestra datos, y el
 * gate del propio Server Component sigue aplicando.
 */
const STATIC_ASSET_EXTENSIONS = [
  // tipografías
  "woff", "woff2", "ttf", "otf", "eot",
  // imágenes: las seis que el matcher del middleware ya excluye van igual, para
  // que este predicado sea verdadero por sí mismo y no dependa de que el matcher
  // siga teniendo esa lista — el mismo criterio de causa raíz de D4
  "svg", "png", "jpg", "jpeg", "gif", "webp",
  "ico", "avif", "bmp",
  // 3D y binarios de los decoders (v4-visual-3d-refresh)
  "glb", "gltf", "ktx2", "hdr", "bin", "wasm",
  // multimedia
  "mp4", "webm", "ogg", "mp3", "wav",
  // documentos y datos estáticos servidos desde public/
  "pdf", "csv", "txt", "xml", "json", "map", "webmanifest",
] as const

/** ¿Es la ruta de un archivo estático de `public/`? */
function isStaticAssetPath(pathname: string): boolean {
  const lastSegment = pathname.slice(pathname.lastIndexOf("/") + 1)
  const dot = lastSegment.lastIndexOf(".")
  if (dot <= 0) return false
  const extension = lastSegment.slice(dot + 1).toLowerCase()
  return (STATIC_ASSET_EXTENSIONS as readonly string[]).includes(extension)
}

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
  if (isStaticAssetPath(pathname)) return true
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
