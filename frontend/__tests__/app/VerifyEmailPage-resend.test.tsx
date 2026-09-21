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

// setHandlers + fireExpire/fireError (MAJOR 2 de la revisión adversarial: el
// doble original declaraba `onExpire`/`onError` en el tipo y los descartaba,
// a diferencia de los 4 dobles de referencia — `ForgotPasswordPage.test.tsx`,
// `LoginPage.test.tsx`, `RegisterPage.test.tsx`, `MagicLinkForm.test.tsx` —
// que sí los cablean). Sin esto, la auto-renovación por visibilidad de
// `CaptchaWidget` (que llega al gate únicamente vía `onExpire`) queda sin
// cobertura en la pantalla más longeva de auth.
const captchaHandlers = vi.hoisted(() => {
  let handlers: { onExpire?: () => void; onError?: () => void } = {}
  return {
    setHandlers(next: { onExpire?: () => void; onError?: () => void }) {
      handlers = next
    },
    fireExpire() {
      handlers.onExpire?.()
    },
    fireError() {
      handlers.onError?.()
    },
  }
})

vi.mock("@/components/auth/CaptchaWidget", () => ({
  CaptchaWidget: React.forwardRef(
    (
      {
        onVerify,
        onExpire,
        onError,
      }: { onVerify: (t: string) => void; onExpire?: () => void; onError?: () => void },
      ref: React.Ref<unknown>,
    ) => {
      captchaHandlers.setHandlers({ onExpire, onError })
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

// ── MAJOR 1 de la revisión adversarial ──────────────────────────────────────
//
// `/auth/verify-email` es la primera pantalla cuyo botón de submit sobrevive a
// su propio éxito (las otras 4 desmontan el form o navegan). Sin consumir el
// token tras un envío exitoso, el 2º reenvío (pasado el cooldown de 30 s, muy
// por debajo de los ~120 s de frescura) reenviaría el MISMO token ya gastado
// por Cloudflare, y GoTrue respondería `timeout-or-duplicate` — una petición
// condenada de antemano que además consume cupo del limiter de `/resend`.
describe("/auth/verify-email — el token se consume tras un envío exitoso (MAJOR 1)", () => {
  it("tras el éxito, el widget se resetea (consumeToken) en vez de conservar el token ya usado", async () => {
    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    solveCaptcha()
    await runCooldown()

    const button = await screen.findByRole("button", { name: /^reenviar email$/i })
    await act(async () => {
      button.click()
    })

    await waitFor(() => expect(resendMock).toHaveBeenCalledTimes(1))
    expect(captchaResetMock).toHaveBeenCalledTimes(1)
  })

  it("(triangulate) un segundo click sin resolver de nuevo el captcha NO reenvía hasta que llegue un token fresco", async () => {
    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    solveCaptcha()
    await runCooldown()

    const firstButton = await screen.findByRole("button", { name: /^reenviar email$/i })
    await act(async () => {
      firstButton.click()
    })
    await waitFor(() => expect(resendMock).toHaveBeenCalledTimes(1))

    // El cooldown de UX se reinicia tras el éxito; la compuerta de captcha,
    // en cambio, quedó en 'renewing' (consumeToken) — son dos gates distintos.
    await runCooldown()

    const secondButton = screen.getByRole("button", { name: /reenviar email|renovando verificación/i })
    await act(async () => {
      secondButton.click()
    })
    // Sin un challenge nuevo resuelto, la intención queda encolada: no se
    // dispara un segundo reenvío con el token viejo.
    expect(resendMock).toHaveBeenCalledTimes(1)

    // Recién al resolverse un challenge nuevo (auto-renovación real de
    // Turnstile en producción) se dispara la intención encolada.
    solveCaptcha()
    await waitFor(() => expect(resendMock).toHaveBeenCalledTimes(2))
  })
})

// ── MAJOR 2 de la revisión adversarial ──────────────────────────────────────
//
// El doble original no cableaba `onExpire`/`onError`, así que la auto-
// renovación por visibilidad (que llega al gate únicamente vía `onExpire`)
// tenía cobertura cero en esta pantalla, a diferencia de las otras 4. Mismo
// test que fija `ForgotPasswordPage.test.tsx` para el guard mezclado
// (cooldown/resending + aria-disabled de la renovación).
describe("/auth/verify-email — estado de renovación del captcha (MAJOR 2)", () => {
  it("tras onExpire con token previo, el botón muestra el rótulo de renovación; un click no reenvía todavía y sí lo hace una vez al llegar el token fresco", async () => {
    render(<VerifyEmailPage />)
    await screen.findByRole("button", { name: /reenviar email/i })
    solveCaptcha()
    await runCooldown()

    const button = await screen.findByRole("button", { name: /^reenviar email$/i })
    expect(button).not.toHaveAttribute("aria-disabled")

    act(() => captchaHandlers.fireExpire())

    expect(button).toHaveTextContent("Renovando verificación…")
    expect(button).toHaveAttribute("aria-disabled", "true")
    expect(button).not.toBeDisabled()

    await act(async () => {
      button.click()
    })
    expect(resendMock).not.toHaveBeenCalled()

    solveCaptcha()

    await waitFor(() => expect(resendMock).toHaveBeenCalledTimes(1))
    expect(resendMock).toHaveBeenCalledWith({ email: "susana@test.local", captchaToken: "resend-captcha" })
  })
})
