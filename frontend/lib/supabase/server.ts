import { createServerClient } from '@supabase/ssr'
import { cookies } from 'next/headers'
import { authCookieOptions } from '@/lib/supabase/cookie-options'

export function createClient() {
  const cookieStore = cookies()
  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      // auth-hardening-jwt-cookies (F3): atributos desde la definición
      // compartida — sin esto regía el default de la librería, sin `secure`.
      cookieOptions: authCookieOptions(),
      cookies: {
        async getAll() {
          return (await cookieStore).getAll()
        },
        async setAll(cookiesToSet) {
          try {
            const resolvedStore = await cookieStore
            cookiesToSet.forEach(({ name, value, options }) =>
              resolvedStore.set(name, value, options)
            )
          } catch {
            // The `setAll` method was called from a Server Component.
            // This can be ignored if you have middleware refreshing
            // user sessions.
          }
        },
      },
    }
  )
}
