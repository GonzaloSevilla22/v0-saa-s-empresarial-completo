/**
 * Tests del formulario de registro — change register-name-terms-captcha.
 *
 * El alta ahora pide nombre + apellido (ambos obligatorios), consentimiento de
 * Términos (obligatorio) + opt-in de email (opcional), y un captcha Turnstile que
 * gatea el submit. register() recibe los campos nuevos.
 *
 * El widget Turnstile se mockea (@/components/auth/CaptchaWidget): un botón
 * "solve-captcha" dispara onVerify(token); el ref expone reset().
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor, act } from "@testing-library/react"
import React from "react"
import RegisterPage from "@/app/auth/register/page"
import { TERMS_VERSION } from "@/lib/legal"

const registerMock = vi.fn()
const pushMock = vi.fn()
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

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ register: registerMock }),
}))

vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
}))

vi.mock("next/link", () => ({
  default: ({ href, children }: { href: string; children: React.ReactNode }) => (
    <a href={href}>{children}</a>
  ),
}))

vi.mock("sonner", () => ({
  toast: { error: (...args: unknown[]) => toastErrorMock(...args) },
}))

// Mock del widget Turnstile: botón para resolver el challenge + reset vía ref.
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
        <button type="button" onClick={() => onVerify("captcha-token")}>
          solve-captcha
        </button>
      )
    },
  ),
}))

beforeEach(() => {
  registerMock.mockReset()
  pushMock.mockReset()
  toastErrorMock.mockReset()
  captchaResetMock.mockReset()
  captchaIsStaleMock.mockReset().mockReturnValue(false)
  captchaRefreshMock.mockReset().mockResolvedValue("refreshed-register-captcha")
})

const VALID_PASSWORD = "Passw0rd!"

function fillValidFields() {
  fireEvent.change(screen.getByLabelText("Nombre"), { target: { value: "Susana" } })
  fireEvent.change(screen.getByLabelText("Apellido"), { target: { value: "Giménez" } })
  fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
  fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "+54 9 261 5555555" } })
  fireEvent.change(screen.getByLabelText("Provincia"), { target: { value: "Mendoza" } })
  fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "Godoy Cruz, Mendoza" } })
  fireEvent.change(screen.getByLabelText("Contraseña"), { target: { value: VALID_PASSWORD } })
  fireEvent.change(screen.getByLabelText("Confirmar contraseña"), { target: { value: VALID_PASSWORD } })
}

const solveCaptcha = () => fireEvent.click(screen.getByText("solve-captcha"))
const acceptTerms = () => fireEvent.click(screen.getByTestId("terms-checkbox"))
const submit = () => fireEvent.submit(screen.getByTestId("register-form"))

describe("RegisterPage — nombre/apellido, consentimiento y captcha", () => {
  it("bloquea el submit y avisa si falta el apellido", async () => {
    render(<RegisterPage />)
    fireEvent.change(screen.getByLabelText("Nombre"), { target: { value: "Susana" } })
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "+54 9 261 5555555" } })
    fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "Godoy Cruz, Mendoza" } })
    fireEvent.change(screen.getByLabelText("Contraseña"), { target: { value: VALID_PASSWORD } })
    fireEvent.change(screen.getByLabelText("Confirmar contraseña"), { target: { value: VALID_PASSWORD } })
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/apellido/i))
    })
    expect(registerMock).not.toHaveBeenCalled()
  })

  it("bloquea el submit y avisa si falta la provincia", async () => {
    render(<RegisterPage />)
    fireEvent.change(screen.getByLabelText("Nombre"), { target: { value: "Susana" } })
    fireEvent.change(screen.getByLabelText("Apellido"), { target: { value: "Giménez" } })
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "+54 9 261 5555555" } })
    fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "Godoy Cruz, Mendoza" } })
    fireEvent.change(screen.getByLabelText("Contraseña"), { target: { value: VALID_PASSWORD } })
    fireEvent.change(screen.getByLabelText("Confirmar contraseña"), { target: { value: VALID_PASSWORD } })
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/provincia/i))
    })
    expect(registerMock).not.toHaveBeenCalled()
  })

  it("bloquea el submit si el email no es válido", async () => {
    render(<RegisterPage />)
    fillValidFields()
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "no-es-un-mail" } })
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/email/i))
    })
    expect(registerMock).not.toHaveBeenCalled()
  })

  it("bloquea el submit si el teléfono no es un número válido", async () => {
    render(<RegisterPage />)
    fillValidFields()
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "no-es-tel" } })
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/tel[ée]fono/i))
    })
    expect(registerMock).not.toHaveBeenCalled()
  })

  it("acepta teléfono con prefijo internacional y separadores", async () => {
    registerMock.mockResolvedValue(undefined)
    render(<RegisterPage />)
    fillValidFields()
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "+54 9 261 555-5555" } })
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => expect(registerMock).toHaveBeenCalled())
    expect(registerMock).toHaveBeenCalledWith(
      "Susana",
      "susana@test.com",
      VALID_PASSWORD,
      expect.objectContaining({ phone: "+54 9 261 555-5555" }),
    )
  })

  it("muestra el aviso inline cuando el teléfono es inválido (mientras se escribe)", () => {
    render(<RegisterPage />)
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "22369223654757657" } })
    expect(screen.getByText(/tel[ée]fono válido/i)).toBeInTheDocument()
  })

  it("no muestra el aviso inline si el teléfono es válido", () => {
    render(<RegisterPage />)
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "2236922365" } })
    expect(screen.queryByText(/tel[ée]fono válido/i)).not.toBeInTheDocument()
  })

  it("muestra el aviso inline cuando el email es inválido (mientras se escribe)", () => {
    render(<RegisterPage />)
    fireEvent.change(screen.getByLabelText("Email"), { target: { value: "no-es-un-mail" } })
    expect(screen.getByText(/email válido/i)).toBeInTheDocument()
  })

  it("bloquea el submit y avisa si no se aceptan los Términos", async () => {
    render(<RegisterPage />)
    fillValidFields()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/términos|condiciones/i))
    })
    expect(registerMock).not.toHaveBeenCalled()
  })

  it("deshabilita 'Crear cuenta' hasta resolver el captcha", () => {
    render(<RegisterPage />)
    fillValidFields()
    acceptTerms()

    const submitBtn = screen.getByRole("button", { name: "Crear cuenta" })
    expect(submitBtn).toBeDisabled()

    solveCaptcha()
    expect(submitBtn).toBeEnabled()
  })

  it("los Términos enlazan a las páginas legales públicas", () => {
    render(<RegisterPage />)
    expect(screen.getByRole("link", { name: /términos/i })).toHaveAttribute("href", "/legal/terminos")
    expect(screen.getByRole("link", { name: /privacidad/i })).toHaveAttribute("href", "/legal/privacidad")
  })

  it("registra pasando apellido, versión de términos, opt-in y captchaToken", async () => {
    registerMock.mockResolvedValue(undefined)
    render(<RegisterPage />)
    fillValidFields()
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(registerMock).toHaveBeenCalledWith("Susana", "susana@test.com", VALID_PASSWORD, {
        phone: "+54 9 261 5555555",
        locality: "Godoy Cruz, Mendoza",
        province: "Mendoza",
        lastName: "Giménez",
        termsVersion: TERMS_VERSION,
        emailOptIn: false,
        captchaToken: "captcha-token",
      })
    })
    expect(pushMock).toHaveBeenCalledWith(expect.stringContaining("/auth/verify-email"))
  })

  it("(triangulate) captcha rechazado por Supabase: muestra error, resetea el widget y no navega", async () => {
    registerMock.mockRejectedValue(new Error("captcha protection: request disallowed"))
    render(<RegisterPage />)
    fillValidFields()
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/captcha/i))
    })
    expect(captchaResetMock).toHaveBeenCalled()
    expect(pushMock).not.toHaveBeenCalled()
  })

  it("(triangulate) captcha rechazado en el primer intento: reintenta una vez con token fresco y navega sin toast si entra", async () => {
    registerMock
      .mockRejectedValueOnce(new Error("timeout-or-duplicate"))
      .mockResolvedValueOnce(undefined)
    render(<RegisterPage />)
    fillValidFields()
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => expect(pushMock).toHaveBeenCalledWith(expect.stringContaining("/auth/verify-email")))
    expect(registerMock).toHaveBeenCalledTimes(2)
    expect(registerMock).toHaveBeenNthCalledWith(
      1,
      "Susana",
      "susana@test.com",
      VALID_PASSWORD,
      expect.objectContaining({ captchaToken: "captcha-token" }),
    )
    expect(registerMock).toHaveBeenNthCalledWith(
      2,
      "Susana",
      "susana@test.com",
      VALID_PASSWORD,
      expect.objectContaining({ captchaToken: "refreshed-register-captcha" }),
    )
    expect(toastErrorMock).not.toHaveBeenCalled()
  })

  it("(triangulate) error que no es de captcha: un solo intento, sin refresh", async () => {
    registerMock.mockRejectedValue(new Error("Ya existe una cuenta con ese email"))
    render(<RegisterPage />)
    fillValidFields()
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalledWith("Ya existe una cuenta con ese email"))
    expect(registerMock).toHaveBeenCalledTimes(1)
    expect(captchaRefreshMock).not.toHaveBeenCalled()
  })

  it("(triangulate) token viejo al enviar: se renueva antes de llamar a register()", async () => {
    captchaIsStaleMock.mockReturnValue(true)
    captchaRefreshMock.mockResolvedValue("fresh-before-register")
    registerMock.mockResolvedValue(undefined)
    render(<RegisterPage />)
    fillValidFields()
    acceptTerms()
    solveCaptcha()
    submit()

    await waitFor(() => {
      expect(registerMock).toHaveBeenCalledWith(
        "Susana",
        "susana@test.com",
        VALID_PASSWORD,
        expect.objectContaining({ captchaToken: "fresh-before-register" }),
      )
    })
    expect(registerMock).toHaveBeenCalledTimes(1)
  })
})

describe("RegisterPage — estado de renovación del captcha (change captcha-renewal-feedback)", () => {
  it("tras onExpire con token previo, el botón muestra el rótulo de renovación; un submit no llama a register() y sí lo hace una vez al llegar el token fresco", async () => {
    registerMock.mockResolvedValue(undefined)
    render(<RegisterPage />)
    fillValidFields()
    acceptTerms()
    solveCaptcha()

    const submitBtn = screen.getByRole("button", { name: "Crear cuenta" })
    expect(submitBtn).not.toHaveAttribute("aria-disabled")

    act(() => captchaHandlers.fireExpire())

    expect(submitBtn).toHaveTextContent("Renovando verificación…")
    expect(submitBtn).toHaveAttribute("aria-disabled", "true")
    expect(submitBtn).not.toBeDisabled()

    submit()
    expect(registerMock).not.toHaveBeenCalled()

    solveCaptcha()

    await waitFor(() => expect(registerMock).toHaveBeenCalledTimes(1))
    expect(registerMock).toHaveBeenCalledWith(
      "Susana",
      "susana@test.com",
      VALID_PASSWORD,
      expect.objectContaining({ captchaToken: "captcha-token" }),
    )
  })
})
