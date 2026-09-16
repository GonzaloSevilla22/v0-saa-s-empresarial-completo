import { createBrowserClient } from '@supabase/ssr'
import { authCookieOptions } from '@/lib/supabase/cookie-options'

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    // auth-hardening-jwt-cookies (F3): los atributos de las cookies de sesión
    // vienen de una sola definición compartida por los cuatro sitios que
    // construyen cliente. Sin esto regía el default de la librería, que no
    // tiene clave `secure`.
    { cookieOptions: authCookieOptions() }
  )
}
