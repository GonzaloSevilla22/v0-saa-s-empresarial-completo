import { createServerClient } from '@supabase/ssr'
import { NextResponse, type NextRequest } from 'next/server'

export async function updateSession(request: NextRequest) {
  let supabaseResponse = NextResponse.next({
    request,
  })

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll()
        },
        setAll(cookiesToSet) {
          cookiesToSet.forEach(({ name, value, options }) => request.cookies.set(name, value))
          supabaseResponse = NextResponse.next({
            request,
          })
          cookiesToSet.forEach(({ name, value, options }) =>
            supabaseResponse.cookies.set(name, value, options)
          )
        },
      },
    }
  )

  const {
    data: { user },
    error: authError
  } = await supabase.auth.getUser()

  // Handle stale sessions after a local DB reset
  if (authError && authError.message.includes('Refresh Token Not Found')) {
    // Clear cookies to avoid infinite loops and console noise
    const response = NextResponse.redirect(new URL('/auth/login', request.url))
    request.cookies.getAll().forEach(cookie => {
      if (cookie.name.startsWith('sb-')) {
        response.cookies.delete(cookie.name)
      }
    })
    return response
  }

  const isAuthRoute =
    request.nextUrl.pathname.startsWith('/auth/login') ||
    request.nextUrl.pathname.startsWith('/auth/register')

  const protectedRoutes = [
    '/dashboard', '/ventas', '/compras', '/productos', '/stock',
    '/clientes', '/gastos', '/insights', '/simulador', '/comunidad',
    '/cursos', '/configuracion', '/copiloto-ia', '/ferias', '/seguros', '/admin',
  ]
  const isProtected = protectedRoutes.some(r => request.nextUrl.pathname.startsWith(r))

  // ── Zero Trust: no session → login ────────────────────────────────────────
  if (isProtected && !user) {
    const url = request.nextUrl.clone()
    url.pathname = '/auth/login'
    return NextResponse.redirect(url)
  }

  // ── Email not confirmed → verify-email ───────────────────────────────────
  // Supabase can issue a JWT even before email confirmation (email_confirmed_at = null).
  // Block those users from protected routes until they verify.
  if (isProtected && user && !user.email_confirmed_at) {
    const url = request.nextUrl.clone()
    url.pathname = '/auth/verify-email'
    return NextResponse.redirect(url)
  }

  // ── Already authenticated + verified → skip login/register ───────────────
  if (isAuthRoute && user && user.email_confirmed_at) {
    const url = request.nextUrl.clone()
    url.pathname = '/dashboard'
    return NextResponse.redirect(url)
  }

  return supabaseResponse
}
