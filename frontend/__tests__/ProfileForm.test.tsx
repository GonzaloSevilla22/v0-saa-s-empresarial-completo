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

  // qa-integral-modulos G11 (H9): el patrón `trim() || undefined` hacía que
  // VACIAR un campo fuera indistinguible de no tocarlo — la app decía "Perfil
  // actualizado" y al recargar reaparecía el valor viejo, en los 5 campos
  // opcionales. Vaciar = mandar null explícito (la columna se limpia).
  it("vaciar la localidad manda null explícito (el vacío PERSISTE) — H9", async () => {
    updateProfileMock.mockResolvedValue(undefined)
    render(<ProfileForm />)

    fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "   " } })
    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => {
      expect(updateProfileMock).toHaveBeenCalledWith(
        expect.objectContaining({ locality: null }),
      )
    })
    expect(toastSuccessMock).toHaveBeenCalled()
  })

  it("vaciar el nombre del negocio también manda null (los 5 opcionales, mismo trato) — H9", async () => {
    updateProfileMock.mockResolvedValue(undefined)
    render(<ProfileForm />)

    fireEvent.change(screen.getByLabelText("Nombre del negocio"), { target: { value: "" } })
    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => {
      expect(updateProfileMock).toHaveBeenCalledWith(
        expect.objectContaining({ businessName: null }),
      )
    })
  })

  it("no tocar un campo conserva su valor (vaciar ≠ omitir, pero omitir tampoco pisa) — H9", async () => {
    updateProfileMock.mockResolvedValue(undefined)
    render(<ProfileForm />)

    // Solo se toca la localidad; el negocio y el apellido viajan con su valor actual.
    fireEvent.change(screen.getByLabelText("Localidad"), { target: { value: "Godoy Cruz" } })
    fireEvent.click(screen.getByRole("button", { name: /guardar/i }))

    await waitFor(() => {
      expect(updateProfileMock).toHaveBeenCalledWith(
        expect.objectContaining({
          locality: "Godoy Cruz",
          businessName: "Tienda Susana",
          lastName: "Giménez",
        }),
      )
    })
  })
})

// El otro lado del contrato: la capa de contexto tiene que DISTINGUIR
// null (limpiar la columna) de undefined (no enviarla) — antes hacía
// `?? undefined`, que colapsaba ambos y el update omitía la columna.
describe("buildProfileUpdatePayload — null limpia, undefined omite (G11/H9)", () => {
  it("null pasa como null (la columna se vacía)", async () => {
    const { buildProfileUpdatePayload } = await import("@/lib/profile-update")
    const payload = buildProfileUpdatePayload({ name: "Susana", locality: null })
    expect(payload).toHaveProperty("locality", null)
    expect(payload.name).toBe("Susana")
  })

  it("undefined se omite (la columna no se toca)", async () => {
    const { buildProfileUpdatePayload } = await import("@/lib/profile-update")
    const payload = buildProfileUpdatePayload({ name: "Susana" })
    expect(payload).not.toHaveProperty("locality")
    expect(payload).not.toHaveProperty("business_name")
  })

  it("mapea camelCase → snake_case en los campos compuestos", async () => {
    const { buildProfileUpdatePayload } = await import("@/lib/profile-update")
    const payload = buildProfileUpdatePayload({ businessName: "Tienda", lastName: null })
    expect(payload).toHaveProperty("business_name", "Tienda")
    expect(payload).toHaveProperty("last_name", null)
  })
})
