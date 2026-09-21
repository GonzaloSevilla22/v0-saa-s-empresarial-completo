"use server"

/**
 * actions.ts — las siete operaciones que crean, modifican o destruyen la sesión,
 * corriendo en el servidor.
 *
 * auth-hardening-jwt-cookies (Parte C, D1, tasks 18.3 y 18.4a-g). Hasta este
 * change todas salían **del navegador** hacia el proveedor:
 *
 *   signInWithPassword / signInWithOtp / signUp / signOut / updateUser x2
 *       contexts/auth-context.tsx
 *   resetPasswordForEmail   app/auth/forgot-password/page.tsx
 *   updateUser (contraseña) app/auth/reset-password/page.tsx
 *   resend                  app/auth/verify-email/page.tsx
 *   signOut                 lib/auth/idle-logout.ts
 *
 * Con la sesión en cookies `HttpOnly` eso deja de ser posible —el navegador ya no
 * puede escribirlas— y, sobre todo, deja de ser deseable: la respuesta del
 * proveedor trae el **refresh token**, y el objetivo del change es que ese valor
 * no pase nunca por JavaScript del navegador. Acá el único que lo ve es el
 * servidor, que lo guarda en la cookie y no lo devuelve.
 *
 * `exchangeCodeForSession` **no** está en este módulo: ya corría en el servidor
 * (`app/auth/callback/route.ts`), donde tiene que estar porque necesita leer la
 * cookie PKCE del verificador.
 *
 * Contrato de vuelta: `AuthActionResult`, nunca una excepción — ver
 * `lib/auth/auth-result.ts` para el por qué.
 */

import { headers } from "next/headers"
import { createClient } from "@/lib/supabase/server"
import type { AuthActionResult } from "@/lib/auth/auth-result"
import { isLocalOrigin, resolveSiteUrl } from "@/lib/auth/site-url"

// ── Contexto de la petición ─────────────────────────────────────────────────

/**
 * Origen público del sitio para esta petición.
 *
 * Reemplaza los cuatro `getSiteUrl()` que había en el cliente: en el servidor no
 * hay `window.location.origin`, así que el origen sale de los encabezados de la
 * petición (detrás de Vercel, de `x-forwarded-host`/`x-forwarded-proto`).
 *
 * Un `Host` manipulado no abre un agujero de redirect: el proveedor sólo acepta
 * un `emailRedirectTo` que esté en su propia lista de URLs permitidas, así que un
 * origen ajeno hace fallar la operación en vez de mandar el enlace a otro lado.
 */
async function siteUrl(): Promise<string> {
  const requestHeaders = await headers()
  const host = requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host")
  if (!host) return resolveSiteUrl(null, process.env.NEXT_PUBLIC_SITE_URL)

  const forwardedProto = requestHeaders.get("x-forwarded-proto")?.split(",")[0]?.trim()
  const proto = forwardedProto || (isLocalOrigin(`http://${host}`) ? "http" : "https")

  return resolveSiteUrl(`${proto}://${host}`, process.env.NEXT_PUBLIC_SITE_URL)
}

/** Destino de retorno de todo enlace por email: el intercambio del código PKCE. */
async function callbackUrl(next?: string): Promise<string> {
  const base = `${await siteUrl()}/auth/callback`
  // `next` lo fija este módulo, nunca el cliente: no hay caller que pueda pedir
  // el retorno a otra pantalla.
  return next ? `${base}?next=${next}` : base
}

const ok: AuthActionResult = { ok: true }

/** `{ error }` del proveedor → resultado. Nada de PII en el log. */
function toResult(operation: string, error: { message: string } | null): AuthActionResult {
  if (!error) return ok
  console.error(`[auth-actions] ${operation}: ${error.message}`)
  return { ok: false, error: error.message }
}

// ── Entradas ────────────────────────────────────────────────────────────────

/** Metadatos de perfil que el trigger `handle_new_user` copia a `profiles`. */
export interface SignUpProfile {
  name: string
  lastName?: string
  phone?: string
  locality?: string
  province?: string
  termsVersion?: string
  emailOptIn?: boolean
}

// ── 18.3 / 18.4a-g ──────────────────────────────────────────────────────────

/** 18.3 — inicio de sesión con contraseña (+ token de captcha). */
export async function signInWithPasswordAction(input: {
  email: string
  password: string
  captchaToken?: string
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { error } = await supabase.auth.signInWithPassword({
    email: input.email,
    password: input.password,
    // El proveedor valida el captcha server-side cuando está habilitado a nivel
    // proyecto (Turnstile). El token lo resolvió el navegador del usuario y
    // viaja intacto; lo que cambia con este change es que la IP que el proveedor
    // ve es la de egreso del servidor (D20, medido por el PO en la task 24.10).
    options: { captchaToken: input.captchaToken },
  })
  return toResult("signInWithPassword", error)
}

/** 18.4a — registro. */
export async function signUpAction(input: {
  email: string
  password: string
  captchaToken?: string
  profile: SignUpProfile
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { profile } = input
  const { error } = await supabase.auth.signUp({
    email: input.email,
    password: input.password,
    options: {
      // name/last_name/phone/locality + consentimiento viajan en el
      // user_metadata; `handle_new_user` los copia a `profiles` al crear el
      // perfil. `null` (no `undefined`) para los ausentes: es lo que el trigger
      // espera y lo que el JSON conserva.
      data: {
        name: profile.name,
        last_name: profile.lastName || null,
        phone: profile.phone || null,
        locality: profile.locality || null,
        province: profile.province || null,
        terms_version: profile.termsVersion || null,
        // Default false: nadie queda suscripto por accidente (espeja el default
        // de la columna).
        email_notifications_opt_in: profile.emailOptIn ?? false,
      },
      emailRedirectTo: await callbackUrl(),
      captchaToken: input.captchaToken,
    },
  })
  return toResult("signUp", error)
}

/** 18.4b — enlace mágico. */
export async function signInWithMagicLinkAction(input: {
  email: string
  captchaToken?: string
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { error } = await supabase.auth.signInWithOtp({
    email: input.email,
    options: { emailRedirectTo: await callbackUrl(), captchaToken: input.captchaToken },
  })
  return toResult("signInWithOtp", error)
}

/** 18.4c — pedido de recuperación de contraseña. */
export async function requestPasswordResetAction(input: {
  email: string
  captchaToken?: string
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { error } = await supabase.auth.resetPasswordForEmail(input.email, {
    redirectTo: await callbackUrl("/auth/reset-password"),
    captchaToken: input.captchaToken,
  })
  return toResult("resetPasswordForEmail", error)
}

/**
 * 18.4d — reenvío del email de verificación.
 *
 * El límite de 30 s entre reenvíos sigue donde estaba, en la pantalla
 * (`RESEND_COOLDOWN` de `app/auth/verify-email/page.tsx`): es de experiencia. El
 * límite que protege al proveedor es el suyo, y su error vuelve al toast.
 *
 * fix/auth-reenvio-verificacion-captcha: a diferencia de las otras cuatro
 * operaciones de este archivo, esta acción quedó sin `captchaToken` — y el
 * proyecto real tiene Turnstile ACTIVO con `/resend` sin eximir de captcha
 * (medido contra prod: `400 captcha_failed` sin el campo). El botón fallaba
 * siempre; nadie lo vio porque `/resend` tiene tráfico cero.
 */
export async function resendVerificationEmailAction(input: {
  email: string
  captchaToken?: string
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { error } = await supabase.auth.resend({
    type: "signup",
    email: input.email,
    options: { emailRedirectTo: await callbackUrl(), captchaToken: input.captchaToken },
  })
  return toResult("resend", error)
}

/** 18.4e — cambio de contraseña de la sesión en curso. */
export async function updatePasswordAction(input: {
  password: string
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { error } = await supabase.auth.updateUser({ password: input.password })
  return toResult("updateUser(password)", error)
}

/**
 * 18.4f — pedido de cambio de email.
 *
 * La sesión sigue válida con el email anterior hasta que el usuario confirme el
 * nuevo desde el enlace.
 */
export async function requestEmailChangeAction(input: {
  email: string
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { error } = await supabase.auth.updateUser(
    { email: input.email },
    { emailRedirectTo: await callbackUrl() },
  )
  return toResult("updateUser(email)", error)
}

/**
 * 18.4g — cierre de sesión.
 *
 * `scope: "local"` por default (D6): el `signOut()` pelado de la librería es
 * **global**, así que cerrar sesión en el celular revocaba los refresh tokens de
 * todos los dispositivos y tiraba abajo el POS del mostrador. `"global"` es la
 * acción explícita de "cerrar todas las sesiones" y hay que pedirla.
 */
export async function signOutAction(input?: {
  scope?: "local" | "global"
}): Promise<AuthActionResult> {
  const supabase = createClient()
  const { error } = await supabase.auth.signOut({ scope: input?.scope ?? "local" })
  return toResult(`signOut(${input?.scope ?? "local"})`, error)
}
