/**
 * Tests del login — change register-name-terms-captcha.
 * El captcha (Turnstile) gatea el submit; el token viaja a login().
 * El widget Turnstile se mockea (@/components/auth/CaptchaWidget).
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import React from "react"
import LoginPage from "@/app/auth/login/page"

const loginMock = vi.fn()
const pushMock = vi.fn()

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ login: loginMock }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
  useSearchParams: () => ({ get: () => null }),
}))

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => (
    <a href={href}>{children}</a>
  ),
}))

vi.mock("sonner", () => ({ toast: { error: vi.fn() } }))

vi.mock("@/components/auth/MagicLinkForm", () => ({
  MagicLinkForm: () => <div data-testid="magic-link-form" />,
}))

vi.mock("@/components/auth/CaptchaWidget", () => ({
  CaptchaWidget: React.forwardRef(
    ({ onVerify }: { onVerify: (t: string) => void }, ref: React.Ref<unknown>) => {
      React.useImperativeHandle(ref, () => ({ reset: vi.fn() }))
      return (
        <button type="button" onClick={() => onVerify("login-captcha")}>
          solve-captcha
        </button>
      )
    },
  ),
}))

beforeEach(() => {
  loginMock.mockReset()
  pushMock.mockReset()
})

describe("LoginPage — captcha gate", () => {
  it("deshabilita 'Iniciar sesión' hasta resolver el captcha", () => {
    render(<LoginPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.change(screen.getByLabelText("Contraseña"), { target: { value: "Passw0rd!" } })

    const submitBtn = screen.getByRole("button", { name: "Iniciar sesión" })
    expect(submitBtn).toBeDisabled()

    fireEvent.click(screen.getByText("solve-captcha"))
    expect(submitBtn).toBeEnabled()
  })

  it("llama a login() con el captchaToken", async () => {
    loginMock.mockResolvedValue(undefined)
    render(<LoginPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.change(screen.getByLabelText("Contraseña"), { target: { value: "Passw0rd!" } })
    fireEvent.click(screen.getByText("solve-captcha"))
    fireEvent.click(screen.getByRole("button", { name: "Iniciar sesión" }))

    await waitFor(() => {
      expect(loginMock).toHaveBeenCalledWith("susana@test.com", "Passw0rd!", "login-captcha")
    })
  })
})
