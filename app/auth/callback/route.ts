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
            // Use NEXT_PUBLIC_SITE_URL for the redirect to ensure we stay on the right domain
            const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || origin
            return NextResponse.redirect(`${siteUrl}${next}`)
        }
    }

    // If something went wrong, redirect to login with error
    const siteUrl = process.env.NEXT_PUBLIC_SITE_URL || origin
    return NextResponse.redirect(`${siteUrl}/auth/login?error=auth_callback_error`)
}
