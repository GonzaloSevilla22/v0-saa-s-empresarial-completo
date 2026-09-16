/**
 * Tests de recuperación de contraseña — change register-name-terms-captcha.
 * El captcha (Turnstile) gatea el submit; el token viaja con el pedido.
 *
 * auth-hardening-jwt-cookies (Parte C, task 18.4c): la pantalla ya no llama a
 * Supabase directo — llama a `requestPasswordResetAction`, que corre en el
 * servidor y es la única que ve el `redirectTo`. El ciclo de frescura del
 * captcha que estos tests fijan no cambió: sigue pasando por
 * `captchaGate.submit` → `submitWithFreshCaptcha`.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, act } from "@testing-library/react"
import React from "react"
import ForgotPasswordPage from "@/app/auth/forgot-password/page"

const resetPasswordForEmailMock = vi.fn()
const toastErrorMock = vi.fn()
const captchaResetMock = vi.fn()

// submitWithFreshCaptcha (change captcha-token-freshness) llama a
// isStale()/refresh() vía el ref del widget, no sólo a reset().
const captchaIsStaleMock = vi.fn()
const captchaRefreshMock = vi.fn()

// setHandlers + fireExpire/fireError (change captcha-renewal-feedback):
// simulan la invalidación del token que dispara el estado de renovación.
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

// auth-hardening-jwt-cookies (Parte C, task 18.4c): el pedido de recuperación
// pasó a una acción de SERVIDOR. El doble se mueve de seam con él — mockear
// `@/lib/supabase/client` dejaría este archivo verde mientras la pantalla no
// manda nada. Todo lo que estos tests fijan (el ciclo de frescura del captcha:
// reintento único, refresh del token viejo, cola de renovación) se conserva
// intacto: lo único que cambia es la forma del argumento.
vi.mock("@/app/auth/actions", () => ({
  requestPasswordResetAction: (...args: unknown[]) => resetPasswordForEmailMock(...args),
}))

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => (
    <a href={href}>{children}</a>
  ),
}))

vi.mock("sonner", () => ({
  toast: { error: (...args: unknown[]) => toastErrorMock(...args) },
}))

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
        <button type="button" onClick={() => onVerify("reset-captcha")}>
          solve-captcha
        </button>
      )
    },
  ),
}))

beforeEach(() => {
  resetPasswordForEmailMock.mockReset().mockResolvedValue({ ok: true })
  toastErrorMock.mockReset()
  captchaResetMock.mockReset()
  captchaIsStaleMock.mockReset().mockReturnValue(false)
  captchaRefreshMock.mockReset().mockResolvedValue("refreshed-reset-captcha")
})

describe("ForgotPasswordPage — captcha gate", () => {
  it("deshabilita el envío hasta resolver el captcha", () => {
    render(<ForgotPasswordPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })

    const submitBtn = screen.getByRole("button", { name: /enviar enlace/i })
    expect(submitBtn).toBeDisabled()

    fireEvent.click(screen.getByText("solve-captcha"))
    expect(submitBtn).toBeEnabled()
  })

  it("llama a la acción de recuperación con el email y el captchaToken", async () => {
    render(<ForgotPasswordPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.click(screen.getByText("solve-captcha"))
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace/i }))

    await waitFor(() => expect(resetPasswordForEmailMock).toHaveBeenCalled())
    expect(resetPasswordForEmailMock).toHaveBeenCalledWith({
      email: "susana@test.com",
      captchaToken: "reset-captcha",
    })
  })
})

describe("ForgotPasswordPage — frescura del captcha (change captcha-token-freshness)", () => {
  function fillAndSolve() {
    render(<ForgotPasswordPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.click(screen.getByText("solve-captcha"))
  }

  it("captcha rechazado: reintenta una vez y resetPasswordForEmail recibe el token fresco en el 2º intento", async () => {
    resetPasswordForEmailMock
      .mockResolvedValueOnce({ ok: false, error: "captcha protection: request disallowed" })
      .mockResolvedValueOnce({ ok: true })

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace/i }))

    await waitFor(() => expect(resetPasswordForEmailMock).toHaveBeenCalledTimes(2))
    expect(resetPasswordForEmailMock).toHaveBeenNthCalledWith(
      1,
      expect.objectContaining({ email: "susana@test.com", captchaToken: "reset-captcha" }),
    )
    expect(resetPasswordForEmailMock).toHaveBeenNthCalledWith(
      2,
      expect.objectContaining({
        email: "susana@test.com",
        captchaToken: "refreshed-reset-captcha",
      }),
    )
    expect(toastErrorMock).not.toHaveBeenCalled()
    await waitFor(() => expect(screen.getByText(/revisá tu bandeja/i)).toBeInTheDocument())
  })

  it("(triangulate) error que no es de captcha: un solo intento, sin refresh", async () => {
    resetPasswordForEmailMock.mockResolvedValue({ ok: false, error: "Network error" })

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace/i }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith("Network error"))
    expect(resetPasswordForEmailMock).toHaveBeenCalledTimes(1)
    expect(captchaRefreshMock).not.toHaveBeenCalled()
  })

  it("(triangulate) token viejo al enviar: resetPasswordForEmail recibe el token fresco", async () => {
    captchaIsStaleMock.mockReturnValue(true)
    captchaRefreshMock.mockResolvedValue("fresh-before-reset")

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace/i }))

    await waitFor(() => {
      expect(resetPasswordForEmailMock).toHaveBeenCalledWith(
        expect.objectContaining({ email: "susana@test.com", captchaToken: "fresh-before-reset" }),
      )
    })
    expect(resetPasswordForEmailMock).toHaveBeenCalledTimes(1)
  })
})

describe("ForgotPasswordPage — estado de renovación del captcha (change captcha-renewal-feedback)", () => {
  it("tras onExpire con token previo, el botón muestra el rótulo de renovación; un click no envía todavía y sí lo hace una vez al llegar el token fresco", async () => {
    render(<ForgotPasswordPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.click(screen.getByText("solve-captcha"))

    const submitBtn = screen.getByRole("button", { name: /enviar enlace/i })
    expect(submitBtn).not.toHaveAttribute("aria-disabled")

    act(() => captchaHandlers.fireExpire())

    expect(submitBtn).toHaveTextContent("Renovando verificación…")
    expect(submitBtn).toHaveAttribute("aria-disabled", "true")
    expect(submitBtn).not.toBeDisabled()

    fireEvent.click(submitBtn)
    expect(resetPasswordForEmailMock).not.toHaveBeenCalled()

    fireEvent.click(screen.getByText("solve-captcha"))

    await waitFor(() => expect(resetPasswordForEmailMock).toHaveBeenCalledTimes(1))
    expect(resetPasswordForEmailMock).toHaveBeenCalledWith(
      expect.objectContaining({ email: "susana@test.com", captchaToken: "reset-captcha" }),
    )
  })
})
