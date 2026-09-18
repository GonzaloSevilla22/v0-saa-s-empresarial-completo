/**
 * auth-hardening-jwt-cookies — Parte C, task 18.4d.
 *
 * `/auth/verify-email` es la pantalla que **mira todo usuario nuevo**, y su
 * reenvío hacía `supabase.auth.resend()` desde el navegador. Pasa a la acción de
 * servidor `resendVerificationEmailAction`, que es la única que resuelve el
 * `emailRedirectTo`.
 *
 * Lo que este archivo fija —y que un test de la acción sola no prueba— es que el
 * botón siga gateado por el **cooldown de 30 s**, que 18.4d pide conservar
 * explícitamente: sin él la pantalla dispara un reenvío por click y el límite
 * real pasa a ser el del proveedor, con su error en la cara del usuario.
 *
 * Las otras cuatro operaciones de la pantalla (`refreshSession`, `getSession` x2,
 * `onAuthStateChange`) siguen en el navegador **a propósito** en este grupo: las
 * reemplazan `GET /api/auth/status` (19.4b) y el bus de sesión (20.3). Acá van
 * mockeadas en el cliente para que el sondeo no interfiera.
 *
 * fix/auth-reenvio-verificacion-captcha: el proyecto real tiene Turnstile ACTIVO
 * y `/resend` en GoTrue no está exento de captcha (400 captcha_failed medido
 * contra prod sin `captcha_token`) — el botón fallaba SIEMPRE. La pantalla monta
 * ahora `<CaptchaWidget>` + `useCaptchaGate`, mismo patrón que
 * `ForgotPasswordPage.test.tsx`: se mockea `@/components/auth/CaptchaWidget` (no
 * `@/hooks/auth`) para poder ejercitar la política real de frescura
 * (`isStale`/`refresh`) con la MISMA compuerta que usan las otras 4 pantallas.
 */
import { describe, it, expect, vi, beforeEach, afterEach } from "vitest"
import { render, screen, act, waitFor, fireEvent } from "@testing-library/react"
import React from "react"

const resendMock = vi.fn()
const toastSuccessMock = vi.fn()
const toastErrorMock = vi.fn()

vi.mock("@/app/auth/actions", () => ({
  resendVerificationEmailAction: (...args: unknown[]) => resendMock(...args),
}))

// H-5 (humo local del 2026-09-18): la pantalla pasó a pedirle al contexto la
// renovación forzada de la sesión antes de navegar. El reenvío no la ejerce —acá el
// email nunca se verifica—, pero sin el proveedor `useAuth()` lanza. El doble es la
// función, estable entre renders, y no un objeto nuevo por render: `refreshSession`
// viaja en las dependencias de `handleVerified`.
const refreshSessionMock = vi.fn<() => Promise<boolean>>().mockResolvedValue(true)

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ refreshSession: refreshSessionMock }),
}))

// El sondeo de verificación (grupo 19) no es el objeto de este test: sin sesión,
// `checkVerification()` no encuentra nada y la pantalla queda en espera.
vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    // task 19.7b: los cuatro mecanismos de auth de esta pantalla se fueron a
    // `GET /api/auth/status` (19.4b). El doble ya no ofrece `auth`: con
    // `accessToken` configurado `supabase.auth` LANZA (`index.mjs:389`), y un doble
    // que lo siga ofreciendo deja la suite verde mientras producción explota.
  }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: vi.fn() }),
  useSearchParams: () => new URLSearchParams("email=susana@test.local"),
}))

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => (
    <a href={href}>{children}</a>
  ),
}))

vi.mock("sonner", () => ({
  toast: {
    success: (...args: unknown[]) => toastSuccessMock(...args),
    error: (...args: unknown[]) => toastErrorMock(...args),
    info: vi.fn(),
  },
}))

// Mismo doble que `ForgotPasswordPage.test.tsx`: un botón "solve-captcha" que
// dispara `onVerify` con un token fijo, y los tres métodos del ref
// (reset/isStale/refresh) como mocks controlables por test — necesarios para
// ejercitar `submitWithFreshCaptcha` (token viejo → refresh antes de enviar) con
// la compuerta REAL (`useCaptchaGate`, sin mockear).
const captchaResetMock = vi.fn()
const captchaIsStaleMock = vi.fn()
const captchaRefreshMock = vi.fn()

vi.mock("@/components/auth/CaptchaWidget", () => ({
  CaptchaWidget: React.forwardRef(
    (
      { onVerify }: { onVerify: (t: string) => void; onExpire?: () => void; onError?: () => void },
      ref: React.Ref<unknown>,
    ) => {
      React.useImperativeHandle(ref, () => ({
        reset: captchaResetMock,
        isStale: captchaIsStaleMock,
        refresh: captchaRefreshMock,
      }))
      return (
        <button type="button" onClick={() => onVerify("resend-captcha")}>
          solve-captcha
        </button>
      )
    },
  ),
}))

import VerifyEmailPage from "@/app/auth/verify-email/page"

/** Corre los 30 s del cooldown dejando resolver las promesas del sondeo. */
async function runCooldown() {
  for (let second = 0; second < 31; second += 1) {
    // eslint-disable-next-line no-await-in-loop
    await act(async () => {
      vi.advanceTimersByTime(1000)
    })
  }
}

/** Resuelve el challenge simulado — deja la compuerta en fase `ready`. */
function solveCaptcha() {
  fireEvent.click(screen.getByText("solve-captcha"))
}

beforeEach(() => {
  vi.useFakeTimers({ shouldAdvanceTime: true })
  resendMock.mockReset().mockResolvedValue({ ok: true })
  toastSuccessMock.mockReset()
  toastErrorMock.mockReset()
  captchaResetMock.mockReset()
  captchaIsStaleMock.mockReset().mockReturnValue(false)
  captchaRefreshMock.mockReset().mockResolvedValue("refreshed-resend-captcha")
})

afterEach(() => {
  vi.useRealTimers()
})

describe("/auth/verify-email — reenvío por la acción de servidor", () => {
  it("el botón arranca deshabilitado con la cuenta regresiva de 30 s", async () => {
    render(<VerifyEmailPage />)

    const button = await screen.findByRole("button", { name: /reenviar email \(\d+s\)/i })
    expect(button).toBeDisabled()
    expect(resendMock).not.toHaveBeenCalled()
  })

  it("pasados los 30 s, con el captcha resuelto, el click llama a la acción con el email y el token del widget", async () => {
    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    solveCaptcha()

    await runCooldown()

    const button = await screen.findByRole("button", { name: /^reenviar email$/i })
    expect(button).toBeEnabled()

    await act(async () => {
      button.click()
    })

    expect(resendMock).toHaveBeenCalledWith({ email: "susana@test.local", captchaToken: "resend-captcha" })
    await waitFor(() =>
      expect(toastSuccessMock).toHaveBeenCalledWith("Email reenviado. Revisá tu bandeja o spam."),
    )
  })

  it("y el cooldown se reinicia: un segundo click inmediato no reenvía", async () => {
    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    solveCaptcha()
    await runCooldown()

    const button = await screen.findByRole("button", { name: /^reenviar email$/i })
    await act(async () => {
      button.click()
    })
    expect(resendMock).toHaveBeenCalledTimes(1)

    // Sin esperar de nuevo los 30 s, el botón vuelve a estar gateado.
    const gated = await screen.findByRole("button", { name: /reenviar email \(\d+s\)/i })
    expect(gated).toBeDisabled()
    await act(async () => {
      gated.click()
    })
    expect(resendMock).toHaveBeenCalledTimes(1)
  })

  it("un error de la acción se muestra y no se confunde con éxito", async () => {
    resendMock.mockResolvedValue({
      ok: false,
      error: "For security purposes, you can only request this after 60 seconds",
    })

    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    solveCaptcha()
    await runCooldown()

    const button = await screen.findByRole("button", { name: /^reenviar email$/i })
    await act(async () => {
      button.click()
    })

    await waitFor(() =>
      expect(toastErrorMock).toHaveBeenCalledWith(
        "For security purposes, you can only request this after 60 seconds",
      ),
    )
    expect(toastSuccessMock).not.toHaveBeenCalled()
  })
})

// ── fix/auth-reenvio-verificacion-captcha ───────────────────────────────────
describe("/auth/verify-email — gate de captcha", () => {
  it("con el gate sin token utilizable (captcha no resuelto), el botón no dispara la acción", async () => {
    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    // A propósito: NO se resuelve el captcha ("solve-captcha" nunca se clickea).
    await runCooldown()

    // El cooldown ya terminó (el rótulo pasa a "Reenviar email" sin segundos),
    // pero sin token emitido la compuerta sigue en fase `cold` y el botón sigue
    // deshabilitado — el mismo criterio que ya usan login/registro/recuperación.
    const button = await screen.findByRole("button", { name: /^reenviar email$/i })
    expect(button).toBeDisabled()

    await act(async () => {
      button.click()
    })
    expect(resendMock).not.toHaveBeenCalled()
  })

  it("(triangulate) un token vencido se renueva por el helper antes de enviar", async () => {
    // Esta pantalla queda abierta mucho tiempo (el usuario va a revisar su
    // bandeja); el token de Turnstile vence a los ~5 min y submitWithFreshCaptcha
    // es el que lo renueva antes de llamar a la acción — mismo caso que fija
    // ForgotPasswordPage.test.tsx ("token viejo al enviar").
    captchaIsStaleMock.mockReturnValue(true)
    captchaRefreshMock.mockResolvedValue("fresh-resend-captcha")

    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    solveCaptcha()
    await runCooldown()

    const button = await screen.findByRole("button", { name: /^reenviar email$/i })
    await act(async () => {
      button.click()
    })

    await waitFor(() =>
      expect(resendMock).toHaveBeenCalledWith({
        email: "susana@test.local",
        captchaToken: "fresh-resend-captcha",
      }),
    )
    expect(captchaRefreshMock).toHaveBeenCalled()
    // El token viejo del widget nunca llegó a la acción.
    expect(resendMock).not.toHaveBeenCalledWith(
      expect.objectContaining({ captchaToken: "resend-captcha" }),
    )
  })
})
