/**
 * Tests del formulario de registro — teléfono y localidad obligatorios.
 * Spec (2026-06-10): el registro pide 2 campos más (teléfono, localidad),
 * ambos obligatorios, y viajan en el signUp para persistirse en profiles.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import RegisterPage from "@/app/auth/register/page"

const registerMock = vi.fn()
const pushMock = vi.fn()
const toastErrorMock = vi.fn()

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

beforeEach(() => {
  registerMock.mockReset()
  pushMock.mockReset()
  toastErrorMock.mockReset()
})

// Contraseña que cumple las 5 reglas del checklist (8+, número, letra, mayúscula, símbolo)
const VALID_PASSWORD = "Passw0rd!"

function fillBaseFields() {
  fireEvent.change(screen.getByLabelText("Nombre"), { target: { value: "Susana" } })
  fireEvent.change(screen.getByLabelText("Email"), { target: { value: "susana@test.com" } })
  fireEvent.change(screen.getByLabelText("Contraseña"), { target: { value: VALID_PASSWORD } })
  fireEvent.change(screen.getByLabelText("Confirmar contraseña"), { target: { value: VALID_PASSWORD } })
}

describe("RegisterPage — teléfono y localidad obligatorios", () => {
  it("bloquea el submit y avisa si falta el teléfono", async () => {
    render(<RegisterPage />)
    fillBaseFields()
    fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "Godoy Cruz, Mendoza" } })

    fireEvent.submit(screen.getByTestId("register-form"))

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/teléfono/i))
    })
    expect(registerMock).not.toHaveBeenCalled()
  })

  it("bloquea el submit y avisa si falta la localidad", async () => {
    render(<RegisterPage />)
    fillBaseFields()
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "+54 9 261 5555555" } })

    fireEvent.submit(screen.getByTestId("register-form"))

    await waitFor(() => {
      expect(toastErrorMock).toHaveBeenCalledWith(expect.stringMatching(/localidad/i))
    })
    expect(registerMock).not.toHaveBeenCalled()
  })

  it("registra pasando teléfono y localidad cuando el form está completo", async () => {
    registerMock.mockResolvedValue(undefined)
    render(<RegisterPage />)
    fillBaseFields()
    fireEvent.change(screen.getByLabelText("Teléfono"), { target: { value: "+54 9 261 5555555" } })
    fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "Godoy Cruz, Mendoza" } })

    fireEvent.submit(screen.getByTestId("register-form"))

    await waitFor(() => {
      expect(registerMock).toHaveBeenCalledWith("Susana", "susana@test.com", VALID_PASSWORD, {
        phone: "+54 9 261 5555555",
        locality: "Godoy Cruz, Mendoza",
      })
    })
    expect(pushMock).toHaveBeenCalledWith(expect.stringContaining("/auth/verify-email"))
  })
})
