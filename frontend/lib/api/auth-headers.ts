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
 * NOTA PARA LA PARTE C: `resolveAccessToken()` es el único punto que hay que
 * cambiar cuando exista el token handler (`GET /api/auth/token`, D1). Hoy lee
 * la sesión con el cliente de navegador, que es de donde sale el Bearer de
 * todas las llamadas a FastAPI.
 */
import { createClient } from "@/lib/supabase/client"

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

/** Token de acceso vigente, o `null` si no hay sesión. Nunca lanza. */
async function resolveAccessToken(): Promise<string | null> {
  try {
    const supabase = createClient()
    const {
      data: { session },
    } = await supabase.auth.getSession()
    return session?.access_token || null
  } catch {
    // Una sesión que no se puede resolver es, para el transporte, una sesión
    // ausente: la llamada sale sin encabezado y el backend responde 401.
    return null
  }
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
  const token = await resolveAccessToken()
  return {
    ...(extraHeaders ?? {}),
    ...(token ? { Authorization: `Bearer ${token}` } : {}),
  }
}

/**
 * Reacción compartida a un 401 del backend propio (D7).
 *
 * Consulta el estado de sesión: si no hay, navega al login con el motivo de
 * vencimiento y la ruta actual como destino de retorno. Si la sesión sigue
 * viva, el 401 fue por otra razón y el caller conserva su manejo de error.
 *
 * @returns `true` si navegó (no había sesión).
 */
export async function handleUnauthorized(): Promise<boolean> {
  const token = await resolveAccessToken()
  if (token) return false

  const current =
    typeof window === "undefined"
      ? "/dashboard"
      : `${window.location.pathname}${window.location.search}`

  sessionNavigation.assign(
    `/auth/login?reason=expired&next=${encodeURIComponent(current)}`,
  )
  return true
}
