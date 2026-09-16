/**
 * safe-next.ts — validación del parámetro `next` (destino de retorno).
 *
 * auth-hardening-jwt-cookies (D5). Hasta este change había **dos** criterios
 * para el mismo parámetro: el middleware validaba con `next.startsWith("/")`
 * (`lib/supabase/middleware.ts:186`) y `app/auth/callback/route.ts` concatenaba
 * sin validar (`` `${siteUrl}${next}` ``, `:9` y `:43`) — un open redirect
 * latente, porque `@evil.example/` cambia el host del resultado.
 *
 * Acá vive la única implementación. La consumen el middleware y el manejador
 * del callback de los enlaces por email.
 *
 * Criterio: se acepta una ruta interna —empieza por `/` y **no** por `//` ni
 * por `/\`— y se descarta todo lo demás. Se rechazó una allow-list de destinos
 * porque habría que mantenerla al mismo ritmo que las rutas, que es justo el
 * problema que D4 resuelve; `startsWith("/")` sin `//` ni `\` no envejece.
 */

/** Ruta principal del área autenticada: destino cuando el recibido se descarta. */
export const DEFAULT_NEXT = "/dashboard"

/**
 * Devuelve `next` si es una ruta interna del propio sitio; si no, `fallback`.
 *
 * `//evil.example` y `/\evil.example` se descartan porque el navegador los
 * resuelve como URL protocol-relative: `Location: //evil.example` navega a otro
 * host aunque empiece por una barra.
 */
export function safeNext(
  next: string | null | undefined,
  fallback: string = DEFAULT_NEXT,
): string {
  if (!next) return fallback
  if (!next.startsWith("/")) return fallback

  const second = next[1]
  if (second === "/" || second === "\\") return fallback

  return next
}
