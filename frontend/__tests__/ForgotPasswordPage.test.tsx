/**
 * Tests de recuperación de contraseña — change register-name-terms-captcha.
 * El captcha (Turnstile) gatea el submit; el token viaja a resetPasswordForEmail
 * vía options.captchaToken (llamada directa a Supabase, sin pasar por el context).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import React from "react"
import ForgotPasswordPage from "@/app/auth/forgot-password/page"

const resetPasswordForEmailMock = vi.fn()
const toastErrorMock = vi.fn()
const captchaResetMock = vi.fn()

// submitWithFreshCaptcha (change captcha-token-freshness) llama a
// isStale()/refresh() vía el ref del widget, no sólo a reset().
const captchaIsStaleMock = vi.fn()
const captchaRefreshMock = vi.fn()

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({
    auth: { resetPasswordForEmail: resetPasswordForEmailMock },
  }),
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
    ({ onVerify }: { onVerify: (t: string) => void }, ref: React.Ref<unknown>) => {
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
  resetPasswordForEmailMock.mockReset().mockResolvedValue({ error: null })
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

  it("llama a resetPasswordForEmail con options.captchaToken", async () => {
    render(<ForgotPasswordPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.click(screen.getByText("solve-captcha"))
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace/i }))

    await waitFor(() => expect(resetPasswordForEmailMock).toHaveBeenCalled())
    expect(resetPasswordForEmailMock).toHaveBeenCalledWith(
      "susana@test.com",
      expect.objectContaining({ captchaToken: "reset-captcha" }),
    )
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
      .mockResolvedValueOnce({ error: { message: "captcha protection: request disallowed" } })
      .mockResolvedValueOnce({ error: null })

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace/i }))

    await waitFor(() => expect(resetPasswordForEmailMock).toHaveBeenCalledTimes(2))
    expect(resetPasswordForEmailMock).toHaveBeenNthCalledWith(
      1,
      "susana@test.com",
      expect.objectContaining({ captchaToken: "reset-captcha" }),
    )
    expect(resetPasswordForEmailMock).toHaveBeenNthCalledWith(
      2,
      "susana@test.com",
      expect.objectContaining({ captchaToken: "refreshed-reset-captcha" }),
    )
    expect(toastErrorMock).not.toHaveBeenCalled()
    await waitFor(() => expect(screen.getByText(/revisá tu bandeja/i)).toBeInTheDocument())
  })

  it("(triangulate) error que no es de captcha: un solo intento, sin refresh", async () => {
    resetPasswordForEmailMock.mockResolvedValue({ error: { message: "Network error" } })

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
        "susana@test.com",
        expect.objectContaining({ captchaToken: "fresh-before-reset" }),
      )
    })
    expect(resetPasswordForEmailMock).toHaveBeenCalledTimes(1)
  })
})
