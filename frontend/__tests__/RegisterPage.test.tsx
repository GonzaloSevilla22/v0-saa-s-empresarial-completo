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
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import React from "react"
import RegisterPage from "@/app/auth/register/page"
import { TERMS_VERSION } from "@/lib/legal"

const registerMock = vi.fn()
const pushMock = vi.fn()
const toastErrorMock = vi.fn()
const captchaResetMock = vi.fn()

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
    ({ onVerify }: { onVerify: (t: string) => void }, ref: React.Ref<unknown>) => {
      React.useImperativeHandle(ref, () => ({ reset: captchaResetMock }))
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
})
