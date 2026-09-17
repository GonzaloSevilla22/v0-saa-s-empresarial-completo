/**
 * site-url.ts — la ÚNICA resolución de "a qué origen vuelve un enlace por
 * email".
 *
 * auth-hardening-jwt-cookies (Parte C, D1). Al mover las operaciones de auth al
 * servidor (grupo 18), el `emailRedirectTo` deja de poder salir de
 * `window.location.origin`. La resolución estaba copiada **cuatro** veces —y la
 * cuarta con otra regla—:
 *
 *   - `contexts/auth-context.tsx:219-226`  (window.origin, si no envs)
 *   - `app/auth/forgot-password/page.tsx:22-27`  (idem)
 *   - `app/auth/verify-email/page.tsx:39-42`     (idem, más corta)
 *   - `app/auth/callback/route.ts:48-50`         (origen, pero en local prefiere
 *                                                `NEXT_PUBLIC_SITE_URL`)
 *
 * Se conserva la regla del **callback**, que es la única de las cuatro que ya
 * corría en el servidor: el origen de la petición manda, salvo en local, donde
 * se prefiere `NEXT_PUBLIC_SITE_URL` si está definida — así el enlace de un
 * stack local apunta a donde el desarrollador puede abrirlo.
 *
 * La función es **pura** a propósito: los encabezados los lee el caller (una
 * Server Action con `headers()`, o el Route Handler con el origen de su propia
 * URL), y esto queda testeable sin Next.
 */

const LOCAL_HOSTNAMES = new Set(["localhost", "127.0.0.1", "[::1]"])

/** Origen de desarrollo por default: el `pnpm dev` de este repo. */
const DEV_FALLBACK = "http://localhost:3000"

const withoutTrailingSlash = (value: string) => value.replace(/\/+$/, "")

/**
 * ¿El origen apunta al equipo de desarrollo?
 *
 * Compara por **hostname**, no con `origin.includes("localhost")` como hacía el
 * callback: ese predicado daba `true` para `https://localhost.evil.example`. No
 * era explotable (el origen lo pone el servidor), pero la comprobación correcta
 * cuesta lo mismo.
 */
export function isLocalOrigin(origin: string | null | undefined): boolean {
  if (!origin) return false
  try {
    return LOCAL_HOSTNAMES.has(new URL(origin).hostname)
  } catch {
    return false
  }
}

/**
 * Origen público del sitio, sin barra final, listo para concatenarle un path.
 *
 * @param origin    origen de la petición en curso (`https://host`), o `null` si
 *                  no se pudo determinar.
 * @param envSiteUrl valor de `NEXT_PUBLIC_SITE_URL`.
 */
export function resolveSiteUrl(
  origin: string | null | undefined,
  envSiteUrl: string | null | undefined,
): string {
  const configured = withoutTrailingSlash(envSiteUrl ?? "")
  const requested = withoutTrailingSlash(origin ?? "")

  if (!requested) return configured || DEV_FALLBACK
  if (isLocalOrigin(requested)) return configured || requested
  return requested
}
