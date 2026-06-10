/**
 * Tests del formulario de cliente — sección "Datos fiscales" (C-22).
 * CUIT/DNI, condición IVA y razón social opcionales; CUIT con formato
 * correcto pero dígito verificador inválido bloquea el submit.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent, waitFor } from "@testing-library/react"
import { ClientForm } from "@/components/forms/client-form"
import type { Client } from "@/lib/types"

const addClientMock = vi.fn()
const updateClientMock = vi.fn()
const toastErrorMock = vi.fn()
const toastSuccessMock = vi.fn()

vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ addClient: addClientMock, updateClient: updateClientMock }),
}))

vi.mock("sonner", () => ({
  toast: {
    error: (...args: unknown[]) => toastErrorMock(...args),
    success: (...args: unknown[]) => toastSuccessMock(...args),
  },
}))

beforeEach(() => {
  addClientMock.mockReset()
  updateClientMock.mockReset()
  toastErrorMock.mockReset()
  toastSuccessMock.mockReset()
})

const fiscalClient: Client = {
  id: "c-1",
  name: "ACME S.R.L.",
  email: "acme@test.com",
  phone: "",
  status: "activo",
  lastPurchase: "-",
  totalSpent: 0,
  taxId: "30-71234567-1",
  ivaCondition: "responsable_inscripto",
  legalName: "ACME Sociedad",
}

describe("ClientForm — Datos fiscales (C-22)", () => {
  it("renderiza la sección con CUIT/DNI, condición IVA y razón social", () => {
    render(<ClientForm onSuccess={() => {}} />)

    expect(screen.getByText("Datos fiscales")).toBeInTheDocument()
    expect(screen.getByLabelText(/CUIT \/ DNI/i)).toBeInTheDocument()
    expect(screen.getByText(/Condición IVA/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/Razón social/i)).toBeInTheDocument()
  })

  it("bloquea el submit cuando el CUIT tiene dígito verificador inválido", async () => {
    render(<ClientForm onSuccess={() => {}} />)

    fireEvent.change(screen.getByLabelText("Nombre"), { target: { value: "Juan" } })
    fireEvent.change(screen.getByLabelText(/CUIT \/ DNI/i), {
      target: { value: "20-12345678-9" }, // dígito correcto: 6
    })
    fireEvent.click(screen.getByRole("button", { name: /crear cliente/i }))

    await waitFor(() => expect(toastErrorMock).toHaveBeenCalled())
    expect(addClientMock).not.toHaveBeenCalled()
  })

  it("envía los datos fiscales cuando el CUIT es válido", async () => {
    addClientMock.mockResolvedValue(undefined)
    render(<ClientForm onSuccess={() => {}} />)

    fireEvent.change(screen.getByLabelText("Nombre"), { target: { value: "Juan" } })
    fireEvent.change(screen.getByLabelText(/CUIT \/ DNI/i), {
      target: { value: "20-12345678-6" },
    })
    fireEvent.change(screen.getByLabelText(/Razón social/i), {
      target: { value: "Juan Pérez e Hijos" },
    })
    fireEvent.click(screen.getByRole("button", { name: /crear cliente/i }))

    await waitFor(() => {
      expect(addClientMock).toHaveBeenCalledWith(
        expect.objectContaining({
          taxId: "20-12345678-6",
          legalName: "Juan Pérez e Hijos",
        }),
      )
    })
  })

  it("acepta DNI de 8 dígitos sin verificación de dígito", async () => {
    addClientMock.mockResolvedValue(undefined)
    render(<ClientForm onSuccess={() => {}} />)

    fireEvent.change(screen.getByLabelText("Nombre"), { target: { value: "Ana" } })
    fireEvent.change(screen.getByLabelText(/CUIT \/ DNI/i), {
      target: { value: "12345678" },
    })
    fireEvent.click(screen.getByRole("button", { name: /crear cliente/i }))

    await waitFor(() => {
      expect(addClientMock).toHaveBeenCalledWith(
        expect.objectContaining({ taxId: "12345678" }),
      )
    })
    expect(toastErrorMock).not.toHaveBeenCalled()
  })

  it("precarga los datos fiscales en edición y los preserva al guardar", async () => {
    updateClientMock.mockResolvedValue(undefined)
    render(<ClientForm onSuccess={() => {}} initialData={fiscalClient} />)

    expect(screen.getByLabelText(/CUIT \/ DNI/i)).toHaveValue("30-71234567-1")
    expect(screen.getByLabelText(/Razón social/i)).toHaveValue("ACME Sociedad")

    fireEvent.click(screen.getByRole("button", { name: /actualizar cliente/i }))

    await waitFor(() => {
      expect(updateClientMock).toHaveBeenCalledWith(
        expect.objectContaining({
          id: "c-1",
          taxId: "30-71234567-1",
          ivaCondition: "responsable_inscripto",
          legalName: "ACME Sociedad",
        }),
      )
    })
  })
})
