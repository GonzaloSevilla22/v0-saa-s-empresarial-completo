import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { NextResponse, type NextRequest } from 'next/server'

export async function GET(request: NextRequest) {
    const { searchParams, origin } = new URL(request.url)
    const code = searchParams.get('code')
    // 'next' param lets you redirect after confirm (if used)
    const next = searchParams.get('next') ?? '/dashboard'

    if (code) {
        const cookieStore = await cookies()
        const supabase = createServerClient(
            process.env.NEXT_PUBLIC_SUPABASE_URL!,
            process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
            {
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
            console.log(`[Auth Callback] Sesión intercambiada con éxito. Redirigiendo a: ${origin}${next}`)
            // Usamos primariamente el origin request actual. Evitamos quemar el redirect local 
            // de `.env.local` usando NEXT_PUBLIC_SITE_URL que podría pisar producción.
            const siteUrl = origin.includes('localhost') 
                ? (process.env.NEXT_PUBLIC_SITE_URL || origin) 
                : origin

            return NextResponse.redirect(`${siteUrl}${next}`)
        } else {
            console.error(`[Auth Callback] Error intercambiando sesión:`, error.message)
        }
    }

    console.log(`[Auth Callback] Redirigiendo con error auth_callback_error a: ${origin}/auth/login`)
    // If something went wrong, redirect to login with error
    const fallbackUrl = origin.includes('localhost') 
        ? (process.env.NEXT_PUBLIC_SITE_URL || origin) 
        : origin
    return NextResponse.redirect(`${fallbackUrl}/auth/login?error=auth_callback_error`)
}
