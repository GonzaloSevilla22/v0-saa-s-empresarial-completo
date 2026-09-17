import { createServerClient } from "@supabase/ssr"
import { NextResponse, type NextRequest } from "next/server"
import { evaluateIdle } from "@/lib/auth/idle-server"
import { COOKIE_KEYS } from "@/lib/cookies"
import {
  isProtectedPath as isProtectedRoute,
  isApiPath as isApiRoute,
  isApiAuthPath as isApiAuthRoute,
} from "@/lib/auth/route-access"
import { resolveSafeRedirect } from "@/lib/auth/safe-next"
import { authCookieOptions } from "@/lib/supabase/cookie-options"

// ── Security Headers ───────────────────────────────────────────────────────
// Applied to every response. Tune CSP per feature (e.g., add blob: for file previews).
//
// auth-hardening-jwt-cookies (D3): la política llega **armada**, con el nonce de
// esta petición. No se construye acá dentro, porque el mismo valor tiene que
// viajar además en los encabezados de la petición reenviada — y un segundo
// `buildContentSecurityPolicy()` produciría otro nonce, que es exactamente la
// forma de dejar la página en blanco sin que ningún test lo note.
function applySecurityHeaders(response: NextResponse, csp: string): NextResponse {
  const h = response.headers

  h.set("X-Frame-Options", "DENY")
  h.set("X-Content-Type-Options", "nosniff")
  h.set("Referrer-Policy", "strict-origin-when-cross-origin")
  h.set("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
  h.set("X-DNS-Prefetch-Control", "off")

  // HSTS: only in production (local dev has no TLS)
  if (process.env.NODE_ENV === "production") {
    h.set("Strict-Transport-Security", "max-age=31536000; includeSubDomains; preload")
  }

  h.set("Content-Security-Policy", csp)

  return response
}

/**
 * Nonce de una petición. **Uno solo por petición**, reutilizado por todos los
 * scripts de esa respuesta.
 *
 * auth-hardening-jwt-cookies (D3). `crypto.randomUUID()` en base64: 122 bits de
 * entropía y sólo caracteres válidos como valor de fuente de la directiva.
 */
export function generateCspNonce(): string {
  return btoa(crypto.randomUUID())
}

// Cloudflare Turnstile (captcha en auth) carga su script desde
// challenges.cloudflare.com, renderiza el challenge en un iframe de ese dominio
// y hace fetch al mismo → debe permitirse en script-src, connect-src y frame-src,
// o el widget queda bloqueado en producción (la CSP de prod sí aplica).
// Los tutoriales en video (tutorial-videos) embeben el iframe de
// youtube-nocookie.com → permitido SOLO en frame-src (el facade propio de
// TutorialVideo no usa scripts externos, así que script-src no cambia).
// v4-visual-3d-refresh (D7): worker-src no estaba declarado → heredaba
// default-src 'self', que bloquea Web Workers instanciados desde blob: URLs
// (el mecanismo que usan los decoders Draco/KTX2 de R3F/drei, servidos desde el
// propio origen — sin host de terceros).
// Exported for testability (csp-nonce.test.ts, csp-frame-src.test.ts, csp-worker-src.test.ts).
/**
 * La política de esta petición.
 *
 * auth-hardening-jwt-cookies (D3) — acá murió el comentario "loosen for Next.js
 * hydration; tighten later with nonces" que acompañaba a
 * `'unsafe-inline' 'unsafe-eval'` desde que se escribió el archivo. Tres cosas que
 * hay que saber antes de tocar `script-src`:
 *
 * 1. **`'strict-dynamic'` anula `'self'` y todos los hosts** de la directiva en los
 *    navegadores que lo soportan: lo que carga es lo que lleva el nonce, más lo que
 *    un script con nonce inserte. `'self'` y `https://challenges.cloudflare.com`
 *    siguen listados para los navegadores que ignoran `'strict-dynamic'`; en los
 *    demás, Turnstile carga por **propagación de confianza**.
 * 2. **`'wasm-unsafe-eval'` está a propósito.** Retirar `'unsafe-eval'` retira
 *    también la única habilitación de `WebAssembly.instantiate`; los decoders
 *    Draco/KTX2 de R3F/drei la pueden necesitar y descubrirlo en producción sale
 *    caro.
 * 3. **`style-src` conserva `'unsafe-inline'`.** Tailwind y Radix inyectan estilos
 *    en runtime y `components/ui/chart.tsx` emite un `<style>` con
 *    `dangerouslySetInnerHTML`. Eso es `style-src`, no `script-src`.
 */
export function buildContentSecurityPolicy(nonce: string): string {
  const isProduction = process.env.NODE_ENV === "production"

  // `ws:` sólo fuera de producción. Hallazgo de la pasada visual del grupo 22,
  // **preexistente** a este change: el Realtime del Supabase local es
  // `ws://127.0.0.1:54321/realtime/v1/websocket`, y la directiva listaba
  // `http://127.0.0.1:54321` y `wss:` — dos esquemas que no son ése. El navegador
  // lo bloqueaba, así que la campana de notificaciones no funcionaba en desarrollo
  // local. En producción el proyecto es `https://…supabase.co` y su Realtime ya
  // entra por `wss:`: agregar `ws:` ahí sería permitir texto en claro sin motivo.
  const connectSrc = [
    "connect-src",
    "'self'",
    process.env.NEXT_PUBLIC_SUPABASE_URL ?? "",
    process.env.NEXT_PUBLIC_BACKEND_URL ?? "",
    "https://api.resend.com",
    "https://challenges.cloudflare.com",
    "wss:",
    ...(isProduction ? [] : ["ws:"]),
  ].join(" ")

  const scriptSrc = [
    "script-src",
    "'self'",
    `'nonce-${nonce}'`,
    "'strict-dynamic'",
    "'wasm-unsafe-eval'",
    // Turbopack y el HMR del modo desarrollo evalúan código en runtime. En
    // producción no hay ningún camino que lo necesite.
    ...(isProduction ? [] : ["'unsafe-eval'"]),
    "https://challenges.cloudflare.com",
  ].join(" ")

  return [
    "default-src 'self'",
    scriptSrc,
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data:",
    connectSrc,
    "frame-src https://challenges.cloudflare.com https://www.youtube-nocookie.com",
    "worker-src 'self' blob:",
    "frame-ancestors 'none'",
  ].join("; ")
}

// ── Protected routes ───────────────────────────────────────────────────────
// auth-hardening-jwt-cookies (D4): la lista enumerada `PROTECTED_PREFIXES` se
// retiró. La decisión vive ahora en `lib/auth/route-access.ts`, por exclusión:
// allow-list de rutas públicas + protección por defecto de todo lo demás, y un
// test que lee `app/(dashboard)/` del filesystem para que una ruta nueva sin
// cobertura rompa CI en vez de nacer sin gate (F1).
// Re-exportado acá para que los consumidores existentes sigan importando la
// decisión de protección desde el módulo del middleware.
export {
  isProtectedPath,
  isApiPath,
  isApiAuthPath,
  isPublicPath,
  PUBLIC_PREFIXES,
} from "@/lib/auth/route-access"

const AUTH_ROUTES = ["/auth/login", "/auth/register"]

/**
 * Copia a `redirect` las cookies que el servidor escribió durante la petición
 * (`setAll` sobre `supabaseResponse`).
 *
 * auth-hardening-jwt-cookies (D5). Cada salida por redirect construye su propia
 * `NextResponse`, así que la renovación de sesión que ocurrió dentro de
 * `getUser()` se perdía. Hoy es autocurativo —el redirect vuelve a entrar por
 * el matcher dentro de la ventana de `refresh_token_reuse_interval`— pero la
 * receta de `@supabase/ssr` es copiarlas.
 *
 * ⚠️ SÓLO para los redirects que NO cierran la sesión. Las dos ramas cuyo
 * trabajo **es** destruirla (la purga de "Refresh Token Not Found" y el corte
 * por inactividad) NUNCA deben recibir esta copia: reponerles encima las
 * cookies recién escritas anula en silencio la recuperación y el propio corte
 * (B3 de la revisión adversarial). El test negativo que lo fija vive en
 * `__tests__/lib/middleware-redirect-cookies.test.ts`.
 */
function withRotatedSessionCookies(
  redirect: NextResponse,
  source: NextResponse,
): NextResponse {
  source.cookies.getAll().forEach((cookie) => redirect.cookies.set(cookie))
  return redirect
}

/**
 * Encabezados de la petición **reenviada**, con el nonce de esta petición.
 *
 * auth-hardening-jwt-cookies (D3, B1 de la revisión adversarial). Next **no lee
 * `x-nonce`**: obtiene el nonce de sus propios scripts de arranque e hidratación
 * parseando el encabezado de **petición** `content-security-policy`
 * (`next/dist/server/app-render/app-render.js:150` → `getScriptNonceFromHeader`).
 * Con `'strict-dynamic'` —que anula `'self'` y los hosts— omitirlo no es un modo
 * degradado: es pantalla en blanco en el 100% de las páginas de producción. Por eso
 * viajan **los dos** encabezados.
 *
 * Se llama en **cada** punto donde se construye la respuesta, y se llama de nuevo
 * (no se cachea el resultado) porque `request.cookies.set()` de `setAll` muta los
 * encabezados de la petición: copiarlos una sola vez, antes, perdería las cookies
 * renovadas justo en las peticiones autenticadas.
 */
function cspRequestHeaders(request: NextRequest, nonce: string, csp: string): Headers {
  const headers = new Headers(request.headers)
  headers.set("x-nonce", nonce)
  headers.set("content-security-policy", csp)
  return headers
}

// ── Core session update + route protection ────────────────────────────────
export async function updateSession(
  request: NextRequest,
  /**
   * Nonce de esta petición. Lo genera `middleware.ts` **una sola vez** y lo pasa
   * acá; el default existe para los llamadores directos (tests) y nunca para
   * generar un segundo nonce dentro de la misma petición.
   */
  nonce: string = generateCspNonce(),
): Promise<NextResponse> {
  const csp = buildContentSecurityPolicy(nonce)
  /** Opciones de reenvío con el nonce puesto, recalculadas en cada uso. */
  const forward = () => ({ request: { headers: cspRequestHeaders(request, nonce, csp) } })

  const { pathname } = request.nextUrl

  // ── Manejadores de sesión: pasan de largo ────────────────────────────────
  //
  // auth-hardening-jwt-cookies (D19-5; revisión adversarial pre-merge, hallazgo de
  // las dos lentes). `/api/auth/token` y `/api/auth/status` leen la sesión, aplican
  // el mismo corte por inactividad y rotan sus cookies por su cuenta. Lo único que
  // el `getUser()` de acá agregaba era (a) una llamada de red repetida a GoTrue en
  // el camino más caliente que la Parte C introduce —una o dos veces por carga de
  // página, contra los rate limits por IP que D20 acaba de volver compartidos— y
  // (b) la renovación **fuera** del single-flight del manejador, en otro runtime,
  // que es justamente lo que D19-5 existe para evitar. La CSP sí se emite: es lo
  // único que el middleware aporta a esas rutas.
  if (isApiAuthRoute(pathname)) {
    return applySecurityHeaders(NextResponse.next(forward()), csp)
  }

  let supabaseResponse = NextResponse.next(forward())

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      // auth-hardening-jwt-cookies (F3): atributos desde la definición
      // compartida — sin esto regía el default de la librería, sin `secure`.
      cookieOptions: authCookieOptions(),
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value }) => request.cookies.set(name, value))
          // D3: `forward()`, no `{ request }` pelado. Éste es el punto que
          // descartaba los encabezados de petición modificados, y corre justo en
          // las peticiones que rotan cookies — es decir, las autenticadas.
          supabaseResponse = NextResponse.next(forward())
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  /**
   * Respuesta que **destruye** la sesión del navegador y lo devuelve al login.
   *
   * D4: `/api/**` nunca recibe redirect —habría devuelto HTML donde el consumidor
   * espera JSON—, pero sí el borrado: lo que cambia es la forma de la respuesta, no
   * el efecto sobre la sesión. Es la salida de las dos formas de sesión
   * irrecuperable, y por eso vive en una sola función (revisión adversarial de la
   * Parte C: eran dos ramas que tenían que hacer exactamente lo mismo).
   */
  const purgeSession = (): NextResponse => {
    const purge = isApiRoute(pathname)
      ? NextResponse.next(forward())
      : NextResponse.redirect(new URL("/auth/login", request.url))
    request.cookies.getAll().forEach((cookie) => {
      if (cookie.name.startsWith("sb-")) purge.cookies.delete(cookie.name)
    })
    return applySecurityHeaders(purge, csp)
  }

  // getUser() makes a network call to validate the JWT server-side.
  // Never replace this with getSession() in middleware — that trusts the local cookie.
  //
  // El `try` no es decorativo (revisión adversarial de la Parte C): una cookie
  // `sb-*` cuyo cuerpo no sea base64url válido hace **lanzar** a la librería
  // (`Invalid UTF-8 sequence`, `@supabase/ssr/utils/base64url.js`), no devolver
  // `{ error }`. Y este código corre en el 100% de los paths, así que sin atajarla
  // era un **500 en toda la app, `/auth/login` incluido** — sin salida para el
  // usuario, porque la cookie es `HttpOnly` y no la puede borrar desde JS. La
  // sesión ilegible es una sesión irrecuperable: misma salida que la muerta, y el
  // navegador se autocura en una petición.
  let user: Awaited<ReturnType<typeof supabase.auth.getUser>>["data"]["user"] = null
  let authError: { message: string } | null = null
  try {
    const result = await supabase.auth.getUser()
    user = result.data.user
    authError = result.error
  } catch (unreadable) {
    console.warn(
      "[middleware] cookie de sesión ilegible; se purga la sesión y se vuelve al login:",
      unreadable,
    )
    return purgeSession()
  }

  // Stale session after DB reset / token rotation failure
  if (authError?.message.includes("Refresh Token Not Found")) {
    return purgeSession()
  }

  // D4: protegido por exclusión (allow-list pública + `/api/**` nunca gateada
  // por redirect), no por una lista enumerada a mano.
  const isProtected    = isProtectedRoute(pathname)
  const isAuthRoute    = AUTH_ROUTES.some((p) => pathname.startsWith(p))
  const isAdminRoute   = pathname.startsWith("/admin")

  // No session → redirect to login (preserve intended destination)
  if (isProtected && !user) {
    const url  = request.nextUrl.clone()
    url.pathname = "/auth/login"
    url.searchParams.set("next", pathname)
    return applySecurityHeaders(NextResponse.redirect(url), csp)
  }

  // Unverified email → block until confirmed
  if (isProtected && user && !user.email_confirmed_at) {
    const url = request.nextUrl.clone()
    url.pathname = "/auth/verify-email"
    return applySecurityHeaders(withRotatedSessionCookies(NextResponse.redirect(url), supabaseResponse), csp)
  }

  // ── Server-side idle enforcement (defense-in-depth) ─────────────────────
  // Only runs on the protected + authenticated + email-verified happy path.
  // The client timer writes the auth:last-activity cookie on interaction;
  // we only read it here (Decision 1). Background traffic never resets the clock.
  // Scoping: la allow-list pública incluye /auth/*, así que /auth/login nunca
  // queda idle-gated y el redirect no puede entrar en loop (Decision 5).
  if (isProtected && user && user.email_confirmed_at) {
    const rawCookie = request.cookies.get(COOKIE_KEYS.LAST_ACTIVITY)?.value
    const idleResult = evaluateIdle(rawCookie, Date.now())

    if (idleResult.action === "logout") {
      // auth-hardening-jwt-cookies (D6): revocar contra el proveedor ANTES de
      // borrar. Hasta este change esta rama borraba las cookies `sb-*` y la
      // sesión seguía viva en GoTrue, con su refresh token utilizable desde
      // cualquier copia — el caso exacto que el resto del change vuelve
      // imposible de explotar. `scope: 'local'`: el corte por inactividad de un
      // dispositivo no cierra los demás.
      //
      // El cierre NO queda condicionado a que el proveedor conteste: si GoTrue
      // está caído igual borramos y redirigimos, porque de lo contrario una
      // caída del proveedor desactivaría el corte por inactividad entero.
      //
      // Revisión adversarial (MINOR 3): hay que mirar las DOS formas de fallo.
      // auth-js **no lanza** en el caso normal: `_signOut` se come 401/403/404 y
      // **devuelve** `{ error }` para el resto (p. ej. un 5xx de GoTrue). Sin
      // destructurarlo, la sesión quedaba viva en el emisor sin una sola línea de
      // log — exactamente el estado que esta rama existe para cerrar.
      try {
        const { error: signOutError } = await supabase.auth.signOut({ scope: "local" })
        if (signOutError) {
          console.warn(
            "[middleware] idle signOut returned an error (proceeding to clear cookies):",
            signOutError.message,
          )
        }
      } catch (signOutError) {
        console.warn(
          "[middleware] idle signOut failed (proceeding to clear cookies):",
          signOutError,
        )
      }

      // Session is stale: clear auth cookies, lastActivity, and tenant:active
      // (parity with the client logout() path), then redirect to login.
      const url = request.nextUrl.clone()
      url.pathname = "/auth/login"
      url.searchParams.set("reason", "idle")
      url.searchParams.set("next", pathname)
      const redirect = NextResponse.redirect(url)
      // Clear Supabase auth cookies (mirror the "Refresh Token Not Found" branch)
      request.cookies.getAll().forEach((cookie) => {
        if (cookie.name.startsWith("sb-")) redirect.cookies.delete(cookie.name)
      })
      // Clear the activity signal and tenant cookie (parity with client logout)
      redirect.cookies.delete(COOKIE_KEYS.LAST_ACTIVITY)
      redirect.cookies.delete(COOKIE_KEYS.TENANT)
      return applySecurityHeaders(redirect, csp)
    }

    if (idleResult.action === "seed") {
      // Cookie missing or unparseable: treat as just-active and seed it so the
      // next request has a baseline. Never redirect — this is loop-safety (Decision 6).
      supabaseResponse.cookies.set(COOKIE_KEYS.LAST_ACTIVITY, String(Date.now()), {
        path: "/",
        sameSite: "lax",
        maxAge: 60 * 60 * 24 * 7, // WEEK — matches COOKIE_CONFIG
        httpOnly: false,           // must be readable by client JS (Decision 2)
        secure: process.env.NODE_ENV === "production",
      })
    }
    // "proceed" → fall through to normal session/admin/auth handling
  }

  // Admin routes: server-side role check (defense-in-depth)
  if (isAdminRoute && user) {
    const { data: profile } = await supabase
      .from("profiles")
      .select("role")
      .eq("id", user.id)
      .single()

    if (!profile || profile.role !== "admin") {
      const url = request.nextUrl.clone()
      url.pathname = "/dashboard"
      return applySecurityHeaders(withRotatedSessionCookies(NextResponse.redirect(url), supabaseResponse), csp)
    }
  }

  // Authenticated + verified → skip auth pages
  if (isAuthRoute && user?.email_confirmed_at) {
    // D5: el destino de retorno se valida con el helper compartido — el mismo
    // que consumen `app/auth/callback/route.ts` y el formulario de login.
    // `resolveSafeRedirect` fija el origen desde el request, conserva la query
    // del destino en vez de codificarla dentro del path y **comprueba el origen
    // de la URL resuelta** (BLOCKER 1 de la revisión: `new URL(next, base)` sí
    // puede cambiar el host, a diferencia del setter de `pathname` que había
    // antes de esta parte).
    const url = resolveSafeRedirect(request.nextUrl.searchParams.get("next"), request.url)
    return applySecurityHeaders(withRotatedSessionCookies(NextResponse.redirect(url), supabaseResponse), csp)
  }

  return applySecurityHeaders(supabaseResponse, csp)
}
