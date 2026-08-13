/**
 * Tests de MagicLinkForm — change captcha-token-freshness.
 *
 * Sin cobertura propia hasta este change (tasks.md 6.6). El captcha
 * (Turnstile) gatea el submit; el token viaja a loginWithMagicLink() a
 * través de submitWithFreshCaptcha (reintento único + guarda de edad),
 * igual que en login/register/forgot-password.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import React from "react"
import { MagicLinkForm } from "@/components/auth/MagicLinkForm"

const loginWithMagicLinkMock = vi.fn()
const onBackMock = vi.fn()

// submitWithFreshCaptcha (change captcha-token-freshness) llama a
// isStale()/refresh() vía el ref del widget, no sólo a reset().
const captchaResetMock = vi.fn()
const captchaIsStaleMock = vi.fn()
const captchaRefreshMock = vi.fn()

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ loginWithMagicLink: loginWithMagicLinkMock }),
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
        <button type="button" onClick={() => onVerify("magic-link-captcha")}>
          solve-captcha
        </button>
      )
    },
  ),
}))

beforeEach(() => {
  loginWithMagicLinkMock.mockReset()
  onBackMock.mockReset()
  captchaResetMock.mockReset()
  captchaIsStaleMock.mockReset().mockReturnValue(false)
  captchaRefreshMock.mockReset().mockResolvedValue("refreshed-magic-link-captcha")
})

function fillAndSolve() {
  render(<MagicLinkForm onBack={onBackMock} />)
  fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
  fireEvent.click(screen.getByText("solve-captcha"))
}

describe("MagicLinkForm — captcha gate", () => {
  it("deshabilita el envío hasta resolver el captcha", () => {
    render(<MagicLinkForm onBack={onBackMock} />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })

    const submitBtn = screen.getByRole("button", { name: /enviar enlace mágico/i })
    expect(submitBtn).toBeDisabled()

    fireEvent.click(screen.getByText("solve-captcha"))
    expect(submitBtn).toBeEnabled()
  })

  it("llama a loginWithMagicLink con el email y el captchaToken", async () => {
    loginWithMagicLinkMock.mockResolvedValue(undefined)
    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace mágico/i }))

    await waitFor(() => {
      expect(loginWithMagicLinkMock).toHaveBeenCalledWith("susana@test.com", "magic-link-captcha")
    })
    expect(await screen.findByText(/¡enlace enviado!/i)).toBeInTheDocument()
  })

  it("captcha rechazado: resetea el widget, muestra error y no completa", async () => {
    loginWithMagicLinkMock.mockRejectedValue(new Error("captcha protection: request disallowed"))
    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace mágico/i }))

    await waitFor(() => expect(captchaResetMock).toHaveBeenCalled())
    expect(screen.queryByText(/¡enlace enviado!/i)).not.toBeInTheDocument()
  })
})

describe("MagicLinkForm — frescura del captcha (change captcha-token-freshness)", () => {
  it("captcha rechazado: reintenta una vez con token fresco y no muestra error si el reintento entra", async () => {
    loginWithMagicLinkMock
      .mockRejectedValueOnce(new Error("timeout-or-duplicate"))
      .mockResolvedValueOnce(undefined)

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace mágico/i }))

    await waitFor(() => expect(screen.getByText(/¡enlace enviado!/i)).toBeInTheDocument())
    expect(loginWithMagicLinkMock).toHaveBeenCalledTimes(2)
    expect(loginWithMagicLinkMock).toHaveBeenNthCalledWith(1, "susana@test.com", "magic-link-captcha")
    expect(loginWithMagicLinkMock).toHaveBeenNthCalledWith(2, "susana@test.com", "refreshed-magic-link-captcha")
  })

  it("(triangulate) error que no es de captcha: un solo intento, sin refresh", async () => {
    loginWithMagicLinkMock.mockRejectedValue(new Error("Failed to fetch"))
    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace mágico/i }))

    await waitFor(() => expect(screen.getByText("Failed to fetch")).toBeInTheDocument())
    expect(loginWithMagicLinkMock).toHaveBeenCalledTimes(1)
    expect(captchaRefreshMock).not.toHaveBeenCalled()
  })

  it("(triangulate) token viejo al enviar: se renueva antes de llamar a loginWithMagicLink()", async () => {
    captchaIsStaleMock.mockReturnValue(true)
    captchaRefreshMock.mockResolvedValue("fresh-before-magic-link")
    loginWithMagicLinkMock.mockResolvedValue(undefined)

    fillAndSolve()
    fireEvent.click(screen.getByRole("button", { name: /enviar enlace mágico/i }))

    await waitFor(() => {
      expect(loginWithMagicLinkMock).toHaveBeenCalledWith("susana@test.com", "fresh-before-magic-link")
    })
    expect(loginWithMagicLinkMock).toHaveBeenCalledTimes(1)
  })
})
