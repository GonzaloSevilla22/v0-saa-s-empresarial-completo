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
 * ── `httpOnly: true` (Parte C, D1, task 18.1) ───────────────────────────────
 *
 * En la Parte B este valor era `false` **a propósito**: el Bearer de todas las
 * llamadas a FastAPI salía de leer estas cookies desde el navegador
 * (`supabase.auth.getSession()`), así que marcarlas dejaba la app sin forma de
 * autenticarse contra el backend propio (D16). La Parte C reemplaza esa lectura
 * por el *token handler* (`GET /api/auth/token`), que entrega un access token
 * efímero en memoria y **nunca** el refresh token — y recién entonces `HttpOnly`
 * es gratis.
 *
 * ⚠️ ORDEN DENTRO DE LA PARTE C. Este archivo lo marca el **grupo 18** y el
 * cliente de navegador lo adopta en el **19.6**. Entre esos dos commits la app
 * **no** es operable en runtime: el servidor escribe la sesión como `HttpOnly`,
 * el cliente de navegador ya no puede leerla y todavía no existe de dónde tomar
 * el token. Es un estado intermedio de la rama, nunca de `main`: la Parte C es
 * **un** PR y se mergea con el grupo 19 dentro. Ese es exactamente el orden que
 * fija `tasks.md` (18.1 antes de 19.6).
 *
 * Nota de mecánica, para que nadie busque el bug donde no está: en el cliente de
 * navegador `httpOnly` es un **no-op** por construcción — `@supabase/ssr` escribe
 * con `document.cookie` (`cookies.js:103`) y RFC 6265bis §5.5 manda **descartar**
 * una cookie con `HttpOnly` escrita desde una API no-HTTP. El atributo sólo tiene
 * efecto en los caminos de servidor (middleware, Route Handlers, Server Actions),
 * que son los únicos que deben escribir la sesión.
 *
 * No se fijan `maxAge` ni `name`: conservan el default de la librería, para que
 * este módulo cambie atributos y no identidad ni vida de la cookie.
 *
 * NOTA PARA EL DESARROLLO LOCAL: `secure` se decide por `NODE_ENV`, **no** por el
 * transporte de la petición — misma convención que ya usa `lib/cookies.ts`. Eso
 * **no** impide trabajar contra un build de producción en local: los navegadores
 * tratan `http://localhost` como origen **potencialmente confiable** (*potentially
 * trustworthy*, HTML Standard / W3C Secure Contexts) y aceptan y devuelven cookies
 * `Secure` ahí, así que `pnpm build && pnpm start` sobre `http://localhost:3000`
 * loguea igual.
 *
 * Medido en el humo local del **2026-09-18** (H-1): registro, login, cierre de
 * sesión, corte por inactividad, cambio de contraseña y recuperación por email
 * corrieron completos contra `pnpm start`, con las cookies de sesión emitidas como
 * `Secure; HttpOnly; SameSite=lax` (evidencia: `C1-cookies.json`,
 * `C6-renovacion.txt`).
 *
 * La revisión adversarial de la Parte C había anotado lo contrario —que el
 * navegador descartaría esas cookies y que no se podría iniciar sesión así— y la
 * medición lo desmintió. Queda escrito porque esa nota tenía un costo real:
 * empujaba a verificar sólo con `pnpm dev`, que es justo donde la CSP es más laxa y
 * el captcha está stubeado, o sea a **no** probar la política real.
 */
import type { CookieOptions } from "@supabase/ssr"

export function authCookieOptions(): CookieOptions {
  return {
    path: "/",
    // D2 (task 18.2): `Lax`, **no** `Strict`, y no es una omisión.
    //
    // Los cuatro flujos por email (recuperación de contraseña, enlace mágico,
    // confirmación de registro y cambio de email) vuelven a la app por
    // `/auth/callback` como **navegación top-level desde otro sitio**, y ese
    // request necesita llevar la cookie PKCE `…-auth-token-code-verifier` para
    // que `exchangeCodeForSession(code)` pueda cerrar el intercambio. Con
    // `Strict` esa cookie no viaja y los cuatro flujos se rompen.
    //
    // Lo que queda expuesto con `Lax` es el GET top-level cross-site, que no
    // puede mutar nada: toda mutación va por POST a FastAPI con Bearer, no por
    // cookie. `tenant:active` sí conserva su `Strict` (`lib/cookies.ts:40`):
    // no participa de ningún flujo de entrada.
    sameSite: "lax",
    secure: process.env.NODE_ENV === "production",
    // D1 (task 18.1): la sesión deja de ser legible por JavaScript. El
    // encabezado de este archivo explica por qué esto llega recién en la
    // Parte C y qué lo acompaña (grupo 19).
    httpOnly: true,
  }
}
