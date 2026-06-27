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

vi.mock("sonner", () => ({ toast: { error: vi.fn() } }))

vi.mock("@/components/auth/CaptchaWidget", () => ({
  CaptchaWidget: React.forwardRef(
    ({ onVerify }: { onVerify: (t: string) => void }, ref: React.Ref<unknown>) => {
      React.useImperativeHandle(ref, () => ({ reset: vi.fn() }))
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
