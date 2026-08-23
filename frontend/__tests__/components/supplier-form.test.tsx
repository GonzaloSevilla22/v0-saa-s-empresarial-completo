/**
 * SupplierForm — alta y edición (compras-proveedor-cuenta-corriente, task 11.1).
 * Molde de client-form.tsx (D2): reutiliza cuit-utils.ts para la validación de
 * CUIT — sin reimplementarla.
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect, vi, afterEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { SupplierForm } from "@/components/forms/supplier-form"
import type { Supplier } from "@/lib/types"

const addSupplierMock = vi.fn().mockResolvedValue(undefined)
const updateSupplierMock = vi.fn().mockResolvedValue(undefined)

vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({
    addSupplier: addSupplierMock,
    updateSupplier: updateSupplierMock,
  }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

function makeSupplier(overrides: Partial<Supplier> = {}): Supplier {
  return {
    id: "sup-1",
    name: "Distribuidora Mendoza",
    email: "contacto@dm.com",
    phone: "2615551234",
    taxId: "20-12345678-6",
    ivaCondition: "responsable_inscripto",
    legalName: "Distribuidora Mendoza SRL",
    ...overrides,
  }
}

describe("SupplierForm — alta", () => {
  afterEach(() => vi.clearAllMocks())

  it("el nombre es obligatorio: sin nombre, no llama a addSupplier", async () => {
    render(<SupplierForm onSuccess={() => {}} />)
    fireEvent.click(screen.getByRole("button", { name: /crear proveedor/i }))
    expect(addSupplierMock).not.toHaveBeenCalled()
  })

  it("CUIT inválido (dígito verificador incorrecto) bloquea el submit", async () => {
    render(<SupplierForm onSuccess={() => {}} />)
    fireEvent.change(screen.getByLabelText(/nombre/i), { target: { value: "Proveedor X" } })
    // Formato correcto pero dígito verificador incorrecto — el válido es
    // 20-12345678-6 (mismo ejemplo que CUIT_FORMAT_HINT / makeSupplier()).
    fireEvent.change(screen.getByLabelText(/cuit/i), { target: { value: "20-12345678-9" } })
    fireEvent.click(screen.getByRole("button", { name: /crear proveedor/i }))
    expect(addSupplierMock).not.toHaveBeenCalled()
  })

  it("con nombre válido y CUIT válido, crea el proveedor", async () => {
    render(<SupplierForm onSuccess={() => {}} />)
    fireEvent.change(screen.getByLabelText(/nombre/i), { target: { value: "Proveedor X" } })
    fireEvent.change(screen.getByLabelText(/cuit/i), { target: { value: "20-12345678-6" } })
    fireEvent.click(screen.getByRole("button", { name: /crear proveedor/i }))

    await vi.waitFor(() => expect(addSupplierMock).toHaveBeenCalledTimes(1))
    expect(addSupplierMock.mock.calls[0][0]).toMatchObject({
      name: "Proveedor X",
      taxId: "20-12345678-6",
    })
  })

  it("alta solo con nombre (sin datos fiscales) también crea el proveedor", async () => {
    render(<SupplierForm onSuccess={() => {}} />)
    fireEvent.change(screen.getByLabelText(/nombre/i), { target: { value: "Solo Nombre" } })
    fireEvent.click(screen.getByRole("button", { name: /crear proveedor/i }))

    await vi.waitFor(() => expect(addSupplierMock).toHaveBeenCalledTimes(1))
    expect(addSupplierMock.mock.calls[0][0]).toMatchObject({ name: "Solo Nombre" })
  })
})

describe("SupplierForm — edición", () => {
  afterEach(() => vi.clearAllMocks())

  it("precarga los campos desde initialData", () => {
    render(<SupplierForm onSuccess={() => {}} initialData={makeSupplier()} />)
    expect(screen.getByLabelText(/nombre/i)).toHaveValue("Distribuidora Mendoza")
    expect(screen.getByLabelText(/cuit/i)).toHaveValue("20-12345678-6")
  })

  it("al guardar, llama a updateSupplier con el id preservado", async () => {
    render(<SupplierForm onSuccess={() => {}} initialData={makeSupplier()} />)
    fireEvent.click(screen.getByRole("button", { name: /actualizar proveedor/i }))

    await vi.waitFor(() => expect(updateSupplierMock).toHaveBeenCalledTimes(1))
    expect(updateSupplierMock.mock.calls[0][0]).toMatchObject({ id: "sup-1", name: "Distribuidora Mendoza" })
  })
})
