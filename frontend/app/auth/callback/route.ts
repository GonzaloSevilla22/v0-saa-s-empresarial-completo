import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { NextResponse, type NextRequest } from 'next/server'
import { resolveSafeRedirect } from '@/lib/auth/safe-next'
import { authCookieOptions } from '@/lib/supabase/cookie-options'

export async function GET(request: NextRequest) {
    const { searchParams, origin } = new URL(request.url)
    const code = searchParams.get('code')
    // auth-hardening-jwt-cookies (D5): el destino de retorno se valida con el
    // MISMO helper que usan el middleware y el formulario de login. Antes se
    // concatenaba crudo a la URL base (`${siteUrl}${next}`), así que
    // `//evil.example` o `@evil.example/` cambiaban el host del redirect — open
    // redirect latente.
    const rawNext = searchParams.get('next')

    if (code) {
        const cookieStore = await cookies()
        const supabase = createServerClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
            {
                // auth-hardening-jwt-cookies (F3): atributos desde la
                // definición compartida — sin esto regía el default de la
                // librería, sin `secure`.
                cookieOptions: authCookieOptions(),
                cookies: {
                    getAll() {
                        return cookieStore.getAll()
                    },
                    setAll(cookiesToSet) {
                        try {
                            cookiesToSet.forEach(({ name, value, options }) =>
                                cookieStore.set(name, value, options)
                            )
                        } catch {
                            // Can be ignored in Server Components
                        }
                    },
                },
            }
        )

        const { error } = await supabase.auth.exchangeCodeForSession(code)
        if (!error) {
            // Usamos primariamente el origin request actual. Evitamos quemar el redirect local
            // de `.env.local` usando NEXT_PUBLIC_SITE_URL que podría pisar producción.
            const siteUrl = origin.includes('localhost')
                ? (process.env.NEXT_PUBLIC_SITE_URL || origin)
                : origin

            // `resolveSafeRedirect` en vez de concatenar: el origen lo fija el
            // sitio, nunca el parámetro; una eventual query del destino sobrevive
            // en vez de quedar codificada dentro del path; y el origen de la URL
            // ya resuelta se comprueba antes de emitirla (BLOCKER 1 de la
            // revisión: un tabulador en el destino colapsaba `new URL()` en otro
            // host).
            const destination = resolveSafeRedirect(rawNext, siteUrl)
            console.log(`[Auth Callback] Sesión intercambiada con éxito. Redirigiendo a: ${destination.href}`)
            return NextResponse.redirect(destination)
        } else {
            console.error(`[Auth Callback] Error intercambiando sesión:`, error.message)
        }
    }

    console.log(`[Auth Callback] Redirigiendo con error auth_callback_error a: ${origin}/auth/login`)
    // If something went wrong, redirect to login with error
    const fallbackUrl = origin.includes('localhost') 
        ? (process.env.NEXT_PUBLIC_SITE_URL || origin) 
        : origin
    return NextResponse.redirect(new URL('/auth/login?error=auth_callback_error', fallbackUrl))
}
