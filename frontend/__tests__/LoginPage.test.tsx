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
const toastErrorMock = vi.fn()

// Handle falso compartido por el mock de CaptchaWidget: submitWithFreshCaptcha
// (change captcha-token-freshness) llama a isStale()/refresh() vía el ref, no
// sólo a reset(), así que el mock necesita exponer los tres.
const captchaMock = vi.hoisted(() => ({
  isStale: vi.fn(),
  refresh: vi.fn(),
  reset: vi.fn(),
}))

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

vi.mock("sonner", () => ({
  toast: { error: (...args: unknown[]) => toastErrorMock(...args) },
}))

vi.mock("@/components/auth/MagicLinkForm", () => ({
  MagicLinkForm: () => <div data-testid="magic-link-form" />,
}))

vi.mock("@/components/auth/CaptchaWidget", () => ({
  CaptchaWidget: React.forwardRef(
    ({ onVerify }: { onVerify: (t: string) => void }, ref: React.Ref<unknown>) => {
      React.useImperativeHandle(ref, () => ({
        reset: captchaMock.reset,
        isStale: captchaMock.isStale,
        refresh: captchaMock.refresh,
      }))
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
  toastErrorMock.mockReset()
  captchaMock.isStale.mockReset().mockReturnValue(false)
  captchaMock.refresh.mockReset().mockResolvedValue("refreshed-login-captcha")
  captchaMock.reset.mockReset()
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

describe("LoginPage — frescura del captcha (change captcha-token-freshness)", () => {
  function fillAndSolve() {
    render(<LoginPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.change(screen.getByLabelText("Contraseña"), { target: { value: "Passw0rd!" } })
    fireEvent.click(screen.getByText("solve-captcha"))
  }

  it("captcha rechazado por Supabase: reintenta una sola vez con token fresco y navega sin toast si entra", async () => {
    loginMock
      .mockRejectedValueOnce(new Error("captcha protection: request disallowed (timeout-or-duplicate)"))
      .mockResolvedValueOnce(undefined)

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: "Iniciar sesión" }))

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith("/dashboard"))
    expect(loginMock).toHaveBeenCalledTimes(2)
    expect(loginMock).toHaveBeenNthCalledWith(1, "susana@test.com", "Passw0rd!", "login-captcha")
    expect(loginMock).toHaveBeenNthCalledWith(2, "susana@test.com", "Passw0rd!", "refreshed-login-captcha")
    expect(toastErrorMock).not.toHaveBeenCalled()
  })

  it("(triangulate) error que no es de captcha: un solo intento, toast inmediato, sin refresh", async () => {
    loginMock.mockRejectedValue(new Error("Invalid login credentials"))

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: "Iniciar sesión" }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith("Invalid login credentials"))
    expect(loginMock).toHaveBeenCalledTimes(1)
    expect(captchaMock.refresh).not.toHaveBeenCalled()
    expect(captchaMock.reset).toHaveBeenCalled()
    expect(pushMock).not.toHaveBeenCalled()
  })

  it("(triangulate) token viejo al enviar: se renueva antes de llamar a login()", async () => {
    captchaMock.isStale.mockReturnValue(true)
    captchaMock.refresh.mockResolvedValue("fresh-before-submit")
    loginMock.mockResolvedValue(undefined)

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: "Iniciar sesión" }))

    await waitFor(() => {
      expect(loginMock).toHaveBeenCalledWith("susana@test.com", "Passw0rd!", "fresh-before-submit")
    })
    expect(loginMock).toHaveBeenCalledTimes(1)
  })
})
