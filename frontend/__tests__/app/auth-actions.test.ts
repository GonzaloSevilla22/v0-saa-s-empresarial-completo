/**
 * auth-hardening-jwt-cookies — Parte C, D1/D2, tasks 18.3, 18.4a-g, 18.5, 18.7.
 *
 * Antes de este change las siete operaciones que crean, modifican o destruyen la
 * sesión salían **del navegador** hacia el proveedor: `signInWithPassword`,
 * `signUp`, `signInWithOtp`, `resetPasswordForEmail`, `resend` y `updateUser`
 * (contraseña y email) vivían en `contexts/auth-context.tsx` y en las pantallas
 * de `app/auth/`, y `signOut` además en `lib/auth/idle-logout.ts`. Con la sesión
 * en cookies `HttpOnly` eso deja de ser posible —y de ser deseable: el navegador
 * no tiene por qué ver nunca el refresh token que el proveedor devuelve—.
 *
 * Este archivo fija las dos mitades del requirement "Las operaciones de
 * autenticación ocurren en el servidor":
 *
 *  1. que cada operación exista como acción de servidor y le pase al proveedor
 *     exactamente lo que le pasaba antes (captcha incluido), y
 *  2. que el código de navegador ya **no** la invoque — que es la mitad que un
 *     test de la acción sola no prueba.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import fs from "node:fs"
import path from "node:path"
import { fileURLToPath } from "node:url"

const HERE = path.dirname(fileURLToPath(import.meta.url))
const FRONTEND = path.resolve(HERE, "..", "..")

const read = (relative: string) => fs.readFileSync(path.join(FRONTEND, relative), "utf8")

/**
 * Fuente sin las líneas de comentario.
 *
 * Los archivos que este change toca quedan con mucha prosa que **nombra** el
 * patrón viejo para explicar por qué se fue ("antes hacía
 * `supabase.auth.signOut()` pelado"). Un detector que mire la fuente cruda
 * marcaría esa prosa como si fuera código.
 */
const readCode = (relative: string) =>
  read(relative)
    .split("\n")
    .filter((line) => !/^\s*(\*|\/\/|\/\*)/.test(line))
    .join("\n")

// ── Dobles del proveedor, detrás del cliente de SERVIDOR ────────────────────
const signInWithPassword = vi.fn()
const signUp = vi.fn()
const signInWithOtp = vi.fn()
const resetPasswordForEmail = vi.fn()
const resend = vi.fn()
const updateUser = vi.fn()
const signOut = vi.fn()

/** Cuántas veces se construyó el cliente de servidor. */
const createServerClientSpy = vi.fn()

vi.mock("@/lib/supabase/server", () => ({
  createClient: () => {
    createServerClientSpy()
    return {
      auth: {
        signInWithPassword,
        signUp,
        signInWithOtp,
        resetPasswordForEmail,
        resend,
        updateUser,
        signOut,
      },
    }
  },
}))

const requestHeaders = vi.fn(
  () => new Headers({ host: "aliadata.com.ar", "x-forwarded-proto": "https" }),
)

vi.mock("next/headers", () => ({
  headers: async () => requestHeaders(),
}))

import {
  requestEmailChangeAction,
  requestPasswordResetAction,
  resendVerificationEmailAction,
  signInWithMagicLinkAction,
  signInWithPasswordAction,
  signOutAction,
  signUpAction,
  updatePasswordAction,
} from "@/app/auth/actions"

const SITE = "https://aliadata.com.ar"

beforeEach(() => {
  vi.clearAllMocks()
  requestHeaders.mockReturnValue(
    new Headers({ host: "aliadata.com.ar", "x-forwarded-proto": "https" }),
  )
  for (const provider of [
    signInWithPassword,
    signUp,
    signInWithOtp,
    resetPasswordForEmail,
    resend,
    updateUser,
    signOut,
  ]) {
    provider.mockResolvedValue({ error: null })
  }
})

// ── 18.3 ::sign_in_runs_on_the_server ───────────────────────────────────────
describe("el módulo de acciones corre en el servidor", () => {
  it("::sign_in_runs_on_the_server — recibe credenciales + captcha y es el servidor el que contacta al proveedor", async () => {
    const result = await signInWithPasswordAction({
      email: "duenio@test.local",
      password: "Passw0rd!",
      captchaToken: "captcha-xyz",
    })

    expect(result).toEqual({ ok: true })
    expect(signInWithPassword).toHaveBeenCalledWith({
      email: "duenio@test.local",
      password: "Passw0rd!",
      options: { captchaToken: "captcha-xyz" },
    })
    // El cliente es el de SERVIDOR: el único que escribe las cookies con las
    // opciones compartidas (`authCookieOptions()`, httpOnly incluido).
    expect(createServerClientSpy).toHaveBeenCalledTimes(1)
  })

  it("el archivo declara la directiva de servidor", () => {
    // Sin la directiva el módulo se empaquetaría para el navegador y estas
    // "acciones" volverían a ser llamadas del cliente al proveedor: es la única
    // línea que hace que todo lo demás de este archivo signifique algo.
    const source = read("app/auth/actions.ts")
    expect(source.trimStart().startsWith('"use server"')).toBe(true)
  })

  it("y no importa el cliente de navegador", () => {
    expect(read("app/auth/actions.ts")).not.toContain("@/lib/supabase/client")
  })

  it("un error del proveedor vuelve como resultado, no como excepción", async () => {
    // Una excepción dentro de una acción de servidor le llega al navegador
    // enmascarada ("An error occurred in the Server Components render"), así que
    // el mensaje que hoy ve el usuario en el toast se perdería.
    signInWithPassword.mockResolvedValue({ error: { message: "Invalid login credentials" } })

    await expect(
      signInWithPasswordAction({ email: "duenio@test.local", password: "mala" }),
    ).resolves.toEqual({ ok: false, error: "Invalid login credentials" })
  })
})

// ── 18.4a-g: una por operación ──────────────────────────────────────────────
describe("las siete operaciones que tocan la sesión", () => {
  it("::sign_up_runs_on_the_server", async () => {
    const result = await signUpAction({
      email: "susana@test.local",
      password: "Passw0rd!",
      captchaToken: "captcha-xyz",
      profile: {
        name: "Susana",
        lastName: "Giménez",
        phone: "+54 9 261 5555555",
        locality: "Godoy Cruz, Mendoza",
        province: "Mendoza",
        termsVersion: "2026-06-v1",
        emailOptIn: true,
      },
    })

    expect(result).toEqual({ ok: true })
    expect(signUp).toHaveBeenCalledWith({
      email: "susana@test.local",
      password: "Passw0rd!",
      options: {
        data: {
          name: "Susana",
          last_name: "Giménez",
          phone: "+54 9 261 5555555",
          locality: "Godoy Cruz, Mendoza",
          province: "Mendoza",
          terms_version: "2026-06-v1",
          email_notifications_opt_in: true,
        },
        emailRedirectTo: `${SITE}/auth/callback`,
        captchaToken: "captcha-xyz",
      },
    })
  })

  it("::sign_up_runs_on_the_server — el opt-in ausente NO suscribe a nadie", async () => {
    await signUpAction({
      email: "susana@test.local",
      password: "Passw0rd!",
      profile: { name: "Susana" },
    })

    const options = signUp.mock.calls[0][0].options
    expect(options.data.email_notifications_opt_in).toBe(false)
    // Los campos opcionales ausentes viajan como null, que es lo que
    // `handle_new_user` copia a `profiles` (no `undefined`, que el JSON come).
    expect(options.data.last_name).toBeNull()
    expect(options.data.phone).toBeNull()
  })

  it("::magic_link_runs_on_the_server", async () => {
    await signInWithMagicLinkAction({ email: "duenio@test.local", captchaToken: "captcha-xyz" })

    expect(signInWithOtp).toHaveBeenCalledWith({
      email: "duenio@test.local",
      options: { emailRedirectTo: `${SITE}/auth/callback`, captchaToken: "captcha-xyz" },
    })
  })

  it("::password_reset_request_runs_on_the_server", async () => {
    await requestPasswordResetAction({ email: "duenio@test.local", captchaToken: "captcha-xyz" })

    expect(resetPasswordForEmail).toHaveBeenCalledWith("duenio@test.local", {
      // El destino del enlace lo fija el SERVIDOR, no el cliente: es lo único
      // que impide que un caller pida el retorno a otra pantalla.
      redirectTo: `${SITE}/auth/callback?next=/auth/reset-password`,
      captchaToken: "captcha-xyz",
    })
  })

  it("::verification_resend_runs_on_the_server — con captchaToken lo pasa junto a emailRedirectTo", async () => {
    // fix/auth-reenvio-verificacion-captcha: el proyecto real tiene Turnstile
    // ACTIVO y GoTrue exige `captcha_token` en `/resend` — sin este campo el
    // botón fallaba SIEMPRE en producción (probado hoy: 400 captcha_failed).
    await resendVerificationEmailAction({ email: "susana@test.local", captchaToken: "captcha-resend" })

    expect(resend).toHaveBeenCalledWith({
      type: "signup",
      email: "susana@test.local",
      options: { emailRedirectTo: `${SITE}/auth/callback`, captchaToken: "captcha-resend" },
    })
  })

  it("::verification_resend_runs_on_the_server — sin captchaToken no inventa uno", async () => {
    await resendVerificationEmailAction({ email: "susana@test.local" })

    expect(resend).toHaveBeenCalledWith({
      type: "signup",
      email: "susana@test.local",
      options: { emailRedirectTo: `${SITE}/auth/callback`, captchaToken: undefined },
    })
    // MINOR 1 de la revisión adversarial: `toHaveBeenCalledWith` usa la misma
    // igualdad recursiva que `toEqual`, que ignora propiedades en `undefined`
    // — la aserción de arriba pasaría igual si la acción OMITIERA la clave
    // por completo. Esta fija la forma real: la clave viaja siempre, sólo su
    // valor es `undefined` sin token.
    expect("captchaToken" in resend.mock.calls[0][0].options).toBe(true)
  })

  it("::verification_resend_runs_on_the_server — el contrato de error no cambia", async () => {
    resend.mockResolvedValue({
      error: { message: "For security purposes, you can only request this after 60 seconds" },
    })

    await expect(
      resendVerificationEmailAction({ email: "susana@test.local", captchaToken: "captcha-resend" }),
    ).resolves.toEqual({
      ok: false,
      error: "For security purposes, you can only request this after 60 seconds",
    })
  })

  it("::verification_resend_runs_on_the_server — el límite de 30 s sigue en la pantalla", () => {
    // 18.4d lo pide explícitamente: el cooldown es de experiencia y se conserva
    // donde estaba. La acción no lo reimplementa ni lo pierde.
    const page = read("app/auth/verify-email/page.tsx")
    expect(page).toMatch(/const RESEND_COOLDOWN\s*=\s*30\b/)
    expect(page).toContain("setCooldown(RESEND_COOLDOWN)")
  })

  it("::password_change_runs_on_the_server", async () => {
    await updatePasswordAction({ password: "NuevaPassw0rd!" })

    expect(updateUser).toHaveBeenCalledWith({ password: "NuevaPassw0rd!" })
  })

  it("::email_change_runs_on_the_server", async () => {
    await requestEmailChangeAction({ email: "nuevo@test.local" })

    expect(updateUser).toHaveBeenCalledWith(
      { email: "nuevo@test.local" },
      { emailRedirectTo: `${SITE}/auth/callback` },
    )
  })

  it("::sign_out_runs_on_the_server — alcance local por default (D6)", async () => {
    await signOutAction()

    expect(signOut).toHaveBeenCalledWith({ scope: "local" })
  })

  it("::sign_out_runs_on_the_server — y 'global' sólo cuando se pide explícitamente", async () => {
    await signOutAction({ scope: "global" })

    expect(signOut).toHaveBeenCalledWith({ scope: "global" })
  })
})

// ── 18.5 ::captcha_token_still_reaches_the_provider ─────────────────────────
describe("el captcha sobrevive el salto al servidor", () => {
  it("::captcha_token_still_reaches_the_provider — las tres operaciones gateadas lo propagan", async () => {
    await signInWithPasswordAction({ email: "a@test.local", password: "Passw0rd!", captchaToken: "t1" })
    await signUpAction({ email: "b@test.local", password: "Passw0rd!", captchaToken: "t2", profile: { name: "B" } })
    await signInWithMagicLinkAction({ email: "c@test.local", captchaToken: "t3" })

    expect(signInWithPassword.mock.calls[0][0].options.captchaToken).toBe("t1")
    expect(signUp.mock.calls[0][0].options.captchaToken).toBe("t2")
    expect(signInWithOtp.mock.calls[0][0].options.captchaToken).toBe("t3")
    await requestPasswordResetAction({ email: "d@test.local", captchaToken: "t4" })
    expect(resetPasswordForEmail.mock.calls[0][1].captchaToken).toBe("t4")
  })

  // Regla del proyecto: `submitWithFreshCaptcha` (vía `captchaGate.submit`) es
  // el ÚNICO camino de envío en una pantalla con captcha. El salto al servidor
  // es justo el refactor donde es fácil perderlo: basta llamar a la acción
  // directo en el `handleSubmit`.
  const CAPTCHA_SCREENS: Array<[string, string]> = [
    ["app/auth/login/page.tsx", "login("],
    ["app/auth/register/page.tsx", "register("],
    ["components/auth/MagicLinkForm.tsx", "loginWithMagicLink("],
    ["app/auth/forgot-password/page.tsx", "requestPasswordResetAction("],
    // fix/auth-reenvio-verificacion-captcha: quinta pantalla gateada.
    ["app/auth/verify-email/page.tsx", "resendVerificationEmailAction("],
  ]

  function submitsThroughGate(source: string, call: string): boolean {
    const escaped = call.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
    return new RegExp(`captchaGate\\.submit\\([\\s\\S]{0,300}?${escaped}`).test(source)
  }

  it.each(CAPTCHA_SCREENS)("%s envía a través de captchaGate.submit", (file, call) => {
    expect(submitsThroughGate(read(file), call)).toBe(true)
  })

  it("el detector no es vacuo: una pantalla que llama directo no pasa", () => {
    const offending = `
      async function handleSubmit() {
        await requestPasswordResetAction({ email })
      }
    `
    expect(submitsThroughGate(offending, "requestPasswordResetAction(")).toBe(false)
  })
})

// ── La otra mitad: el navegador ya no invoca al proveedor ───────────────────
describe("el código de navegador ya no invoca al proveedor", () => {
  const MOVED: Array<[string, string[]]> = [
    [
      "contexts/auth-context.tsx",
      ["signInWithPassword", "signInWithOtp", "signUp", "signOut", "updateUser"],
    ],
    ["app/auth/forgot-password/page.tsx", ["resetPasswordForEmail"]],
    ["app/auth/reset-password/page.tsx", ["updateUser"]],
    ["app/auth/verify-email/page.tsx", ["resend"]],
    ["lib/auth/idle-logout.ts", ["signOut"]],
  ]

  /** `supabase.auth.<op>(` en código. */
  const callsProviderOp = (code: string, op: string) =>
    new RegExp(`\\bauth\\.${op}\\s*\\(`).test(code)

  it.each(MOVED)("%s ya no llama a ninguna de sus operaciones movidas", (file, ops) => {
    const code = readCode(file)
    for (const op of ops) {
      expect(callsProviderOp(code, op), `${file} sigue llamando auth.${op}()`).toBe(false)
    }
  })

  it("el detector reconoce una llamada real (no es vacuo)", () => {
    expect(
      callsProviderOp("const { error } = await supabase.auth.signOut({ scope: 'local' })", "signOut"),
    ).toBe(true)
    // Y el filtro de comentarios no se deja engañar por la prosa, que es lo que
    // estos archivos tienen de sobra después del change.
    expect(readCode("lib/auth/idle-logout.ts")).not.toContain("GoTrueClient")
    expect(read("lib/auth/idle-logout.ts")).toContain("GoTrueClient")
  })

  it("las pantallas movidas consumen las acciones de servidor", () => {
    expect(read("app/auth/forgot-password/page.tsx")).toContain("@/app/auth/actions")
    expect(read("app/auth/reset-password/page.tsx")).toContain("@/app/auth/actions")
    expect(read("app/auth/verify-email/page.tsx")).toContain("@/app/auth/actions")
    expect(read("contexts/auth-context.tsx")).toContain("@/app/auth/actions")
    expect(read("lib/auth/idle-logout.ts")).toContain("@/app/auth/actions")
  })
})

// ── 18.7: el callback escribe con las opciones compartidas ──────────────────
describe("el intercambio del código PKCE (18.7)", () => {
  it("usa las opciones de cookie compartidas y el destino validado", () => {
    const source = read("app/auth/callback/route.ts")
    expect(source).toContain("cookieOptions: authCookieOptions()")
    expect(source).toContain("resolveSafeRedirect(")
  })

  it("y resuelve la URL del sitio con el helper compartido, no con una copia propia", () => {
    expect(read("app/auth/callback/route.ts")).toContain("@/lib/auth/site-url")
    // La quinta copia de `getSiteUrl()` no nació, y las cuatro anteriores se
    // fueron: ninguna pantalla de auth resuelve el origen por su cuenta.
    expect(readCode("app/auth/callback/route.ts")).not.toMatch(
      /origin\.includes\(['"]localhost['"]\)/,
    )
    for (const file of [
      "contexts/auth-context.tsx",
      "app/auth/forgot-password/page.tsx",
      "app/auth/verify-email/page.tsx",
    ]) {
      expect(readCode(file), file).not.toMatch(/const getSiteUrl\s*=/)
    }
  })
})
