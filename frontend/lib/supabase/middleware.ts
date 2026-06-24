import { createServerClient } from "@supabase/ssr"
import { NextResponse, type NextRequest } from "next/server"
import { evaluateIdle } from "@/lib/auth/idle-server"
import { COOKIE_KEYS } from "@/lib/cookies"

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

  // CSP: permissive for now, tighten per module as you build
  h.set(
    "Content-Security-Policy",
    [
      "default-src 'self'",
      "script-src 'self' 'unsafe-inline' 'unsafe-eval'", // loosen for Next.js hydration; tighten later with nonces
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob: https:",
      "font-src 'self' data:",
      `connect-src 'self' ${process.env.NEXT_PUBLIC_SUPABASE_URL ?? ""} ${process.env.NEXT_PUBLIC_BACKEND_URL ?? ""} https://api.resend.com wss:`,
      "frame-ancestors 'none'",
    ].join("; ")
  )

  return response
}

// ── Protected routes ───────────────────────────────────────────────────────
// Exported for testability (idle-server-enforcement.test.ts verifies that
// /auth/* routes are not in this list, ensuring no idle-check loop is possible).
export const PROTECTED_PREFIXES = [
  "/dashboard", "/ventas", "/compras", "/productos", "/stock",
  "/clientes", "/gastos", "/insights", "/simulador", "/comunidad",
  "/cursos", "/configuracion", "/copiloto-ia", "/ferias", "/seguros", "/admin",
]

const AUTH_ROUTES = ["/auth/login", "/auth/register"]

// ── Core session update + route protection ────────────────────────────────
export async function updateSession(request: NextRequest): Promise<NextResponse> {
  let supabaseResponse = NextResponse.next({ request })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
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

  // Stale session after DB reset / token rotation failure
  if (authError?.message.includes("Refresh Token Not Found")) {
    const redirect = NextResponse.redirect(new URL("/auth/login", request.url))
    request.cookies.getAll().forEach((cookie) => {
      if (cookie.name.startsWith("sb-")) redirect.cookies.delete(cookie.name)
    })
    return applySecurityHeaders(redirect)
  }

  const { pathname } = request.nextUrl

  const isProtected    = PROTECTED_PREFIXES.some((p) => pathname.startsWith(p))
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
    return applySecurityHeaders(NextResponse.redirect(url))
  }

  // ── Server-side idle enforcement (defense-in-depth) ─────────────────────
  // Only runs on the protected + authenticated + email-verified happy path.
  // The client timer writes the auth:last-activity cookie on interaction;
  // we only read it here (Decision 1). Background traffic never resets the clock.
  // Scoping: PROTECTED_PREFIXES excludes /auth/*, so /auth/login is never
  // idle-gated and the redirect cannot loop (Decision 5).
  if (isProtected && user && user.email_confirmed_at) {
    const rawCookie = request.cookies.get(COOKIE_KEYS.LAST_ACTIVITY)?.value
    const idleResult = evaluateIdle(rawCookie, Date.now())

    if (idleResult.action === "logout") {
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
      return applySecurityHeaders(NextResponse.redirect(url))
    }
  }

  // Authenticated + verified → skip auth pages
  if (isAuthRoute && user?.email_confirmed_at) {
    const next = request.nextUrl.searchParams.get("next") ?? "/dashboard"
    const url  = request.nextUrl.clone()
    url.pathname = next.startsWith("/") ? next : "/dashboard"
    url.search   = ""
    return applySecurityHeaders(NextResponse.redirect(url))
  }

  return applySecurityHeaders(supabaseResponse)
}
