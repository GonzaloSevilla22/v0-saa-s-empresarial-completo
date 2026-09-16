import { createServerClient } from "@supabase/ssr"
import { NextResponse, type NextRequest } from "next/server"
import { evaluateIdle } from "@/lib/auth/idle-server"
import { COOKIE_KEYS } from "@/lib/cookies"
import { isProtectedPath as isProtectedRoute, isApiPath as isApiRoute } from "@/lib/auth/route-access"
import { safeNext } from "@/lib/auth/safe-next"
import { authCookieOptions } from "@/lib/supabase/cookie-options"

// ── Security Headers ───────────────────────────────────────────────────────
// Applied to every response. Tune CSP per feature (e.g., add blob: for file previews).
function applySecurityHeaders(response: NextResponse): NextResponse {
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

  h.set("Content-Security-Policy", buildContentSecurityPolicy())

  return response
}

// CSP: permissive for now, tighten per module as you build.
// Cloudflare Turnstile (captcha en auth) carga su script desde
// challenges.cloudflare.com, renderiza el challenge en un iframe de ese dominio
// y hace fetch al mismo → debe permitirse en script-src, connect-src y frame-src,
// o el widget queda bloqueado en producción (la CSP de prod sí aplica).
// Los tutoriales en video (tutorial-videos) embeben el iframe de
// youtube-nocookie.com → permitido SOLO en frame-src (el facade propio de
// TutorialVideo no usa scripts externos, así que script-src no cambia).
// v4-visual-3d-refresh (D7): worker-src no estaba declarado → heredaba
// default-src 'self', que bloquea Web Workers instanciados desde blob: URLs
// (el mecanismo que usan los decoders Draco/KTX2 de R3F/drei, self-hosted en
// /public — sin host de terceros). Diff mínimo: solo se agrega esta línea.
// Exported for testability (csp-frame-src.test.ts, csp-worker-src.test.ts).
export function buildContentSecurityPolicy(): string {
  return [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' 'unsafe-eval' https://challenges.cloudflare.com", // loosen for Next.js hydration; tighten later with nonces
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https:",
    "font-src 'self' data:",
    `connect-src 'self' ${process.env.NEXT_PUBLIC_SUPABASE_URL ?? ""} ${process.env.NEXT_PUBLIC_BACKEND_URL ?? ""} https://api.resend.com https://challenges.cloudflare.com wss:`,
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
export { isProtectedPath, isApiPath, isPublicPath, PUBLIC_PREFIXES } from "@/lib/auth/route-access"

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

// ── Core session update + route protection ────────────────────────────────
export async function updateSession(request: NextRequest): Promise<NextResponse> {
  let supabaseResponse = NextResponse.next({ request })

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
          supabaseResponse = NextResponse.next({ request })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  // getUser() makes a network call to validate the JWT server-side.
  // Never replace this with getSession() in middleware — that trusts the local cookie.
  const {
    data: { user },
    error: authError,
  } = await supabase.auth.getUser()

  const { pathname } = request.nextUrl

  // Stale session after DB reset / token rotation failure
  if (authError?.message.includes("Refresh Token Not Found")) {
    // D4: `/api/**` nunca recibe redirect. Esta rama corre ANTES de calcular la
    // ruta y redirigía para cualquier path, así que el manejador de token de la
    // Parte C habría recibido un 307 hacia HTML donde espera JSON. Las cookies
    // muertas se borran igual: lo que cambia es la forma de la respuesta, no el
    // efecto sobre la sesión.
    const purge = isApiRoute(pathname)
      ? NextResponse.next({ request })
      : NextResponse.redirect(new URL("/auth/login", request.url))
    request.cookies.getAll().forEach((cookie) => {
      if (cookie.name.startsWith("sb-")) purge.cookies.delete(cookie.name)
    })
    return applySecurityHeaders(purge)
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
    return applySecurityHeaders(NextResponse.redirect(url))
  }

  // Unverified email → block until confirmed
  if (isProtected && user && !user.email_confirmed_at) {
    const url = request.nextUrl.clone()
    url.pathname = "/auth/verify-email"
    return applySecurityHeaders(withRotatedSessionCookies(NextResponse.redirect(url), supabaseResponse))
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
      try {
        await supabase.auth.signOut({ scope: "local" })
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
      return applySecurityHeaders(redirect)
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
      return applySecurityHeaders(withRotatedSessionCookies(NextResponse.redirect(url), supabaseResponse))
    }
  }

  // Authenticated + verified → skip auth pages
  if (isAuthRoute && user?.email_confirmed_at) {
    // D5: el destino de retorno se valida con el helper compartido — el mismo
    // que consume `app/auth/callback/route.ts`. `new URL(next, request.url)`
    // en vez de asignar a `url.pathname`: fija el origen desde el request y
    // conserva la query del destino en vez de codificarla dentro del path.
    const url = new URL(safeNext(request.nextUrl.searchParams.get("next")), request.url)
    return applySecurityHeaders(withRotatedSessionCookies(NextResponse.redirect(url), supabaseResponse))
  }

  return applySecurityHeaders(supabaseResponse)
}
