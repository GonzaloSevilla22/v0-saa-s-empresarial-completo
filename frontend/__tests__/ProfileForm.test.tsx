/**
 * Tests del formulario de perfil — edición de localidad.
 * El registro guarda profiles.locality (PR #146); el perfil debe permitir
 * verla y editarla después, igual que el teléfono.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { ProfileForm } from "@/components/settings/ProfileForm"

const updateProfileMock = vi.fn()
const toastErrorMock = vi.fn()
const toastSuccessMock = vi.fn()

const baseUser = {
  id: "user-1",
  name: "Susana",
  lastName: "Giménez",
  businessName: "Tienda Susana",
  phone: "+54 9 261 5555555",
  locality: "Maipú, Mendoza",
  bio: "",
  avatar: undefined,
}

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: baseUser, updateProfile: updateProfileMock }),
}))

vi.mock("@/components/settings/AvatarUpload", () => ({
  AvatarUpload: () => <div data-testid="avatar-upload" />,
}))

vi.mock("sonner", () => ({
  toast: {
    error: (...args: unknown[]) => toastErrorMock(...args),
    success: (...args: unknown[]) => toastSuccessMock(...args),
  },
}))

beforeEach(() => {
  updateProfileMock.mockReset()
  toastErrorMock.mockReset()
  toastSuccessMock.mockReset()
})

describe("ProfileForm — localidad editable", () => {
  it("precarga la localidad actual del usuario", () => {
    render(<ProfileForm />)
    expect(screen.getByLabelText("Localidad")).toHaveValue("Maipú, Mendoza")
  })

  it("incluye la localidad editada al guardar", async () => {
    updateProfileMock.mockResolvedValue(undefined)
    render(<ProfileForm />)

    fireEvent.change(screen.getByLabelText("Localidad"), {
      target: { value: "Luján de Cuyo, Mendoza" },
    })
    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => {
      expect(updateProfileMock).toHaveBeenCalledWith(
        expect.objectContaining({ locality: "Luján de Cuyo, Mendoza" }),
      )
    })
    expect(toastSuccessMock).toHaveBeenCalled()
  })

  it("manda la localidad vacía como undefined (no la pisa con string vacío)", async () => {
    updateProfileMock.mockResolvedValue(undefined)
    render(<ProfileForm />)

    fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "   " } })
    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => {
      expect(updateProfileMock).toHaveBeenCalledWith(
        expect.objectContaining({ locality: undefined }),
      )
    })
  })
})
