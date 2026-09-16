/**
 * cookie-options.ts — la ÚNICA definición de los atributos con que se escriben
 * las cookies de sesión de Supabase.
 *
 * auth-hardening-jwt-cookies (F3). Ninguno de los cuatro sitios que construyen
 * cliente pasaba `cookieOptions` (`lib/supabase/client.ts`,
 * `lib/supabase/server.ts`, `lib/supabase/middleware.ts`,
 * `app/auth/callback/route.ts`), así que regía el default de la librería:
 *
 *   { path: "/", sameSite: "lax", httpOnly: false, maxAge: 400 días }
 *   (`@supabase/ssr/dist/main/utils/constants.js`)
 *
 * Ese objeto **no tiene clave `secure`**, y los serializadores sólo emiten el
 * atributo si se lo pasan (`cookie@1.1.1`: `if (cookie.secure) …`; Next 16:
 * `"secure" in c && c.secure && "Secure"`). Resultado medido en producción: las
 * cookies de sesión salían sin `Secure`, mientras las cookies propias de la app
 * sí lo llevaban. En transporte lo tapa HSTS —vivo en prod con
 * `max-age=31536000; includeSubDomains; preload`— pero es una línea que
 * faltaba.
 *
 * ⚠️ `httpOnly` sigue en `false` en la Parte B **a propósito** (D16): el Bearer
 * de todas las llamadas a FastAPI sale hoy de leer esas cookies desde el
 * navegador (`supabase.auth.getSession()`). Ponerlo en `true` sin el token
 * handler de la Parte C deja la app sin forma de autenticarse contra el
 * backend propio.
 *
 * No se fijan `maxAge` ni `name`: conservan el default de la librería, para que
 * este módulo cambie atributos y no identidad ni vida de la cookie.
 */
import type { CookieOptions } from "@supabase/ssr"

export function authCookieOptions(): CookieOptions {
  return {
    path: "/",
    sameSite: "lax",
    // D2: `Lax`, no `Strict` — con `Strict` el retorno de los enlaces por email
    // (recuperación, verificación, cambio de email) llegaría sin cookie.
    secure: process.env.NODE_ENV === "production",
    httpOnly: false,
  }
}
