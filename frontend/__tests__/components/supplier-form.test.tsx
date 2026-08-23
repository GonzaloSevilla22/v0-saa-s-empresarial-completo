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
import { toast } from "sonner"

const addSupplierMock = vi.fn().mockResolvedValue(undefined)
const updateSupplierMock = vi.fn().mockResolvedValue(undefined)
// review B (F4): invalidateQueries mockeado para verificar que, tras un
// error, se re-consulta /suppliers — así el banner de límite de plan
// (usePlanLimits + suppliers.length en proveedores/page.tsx) no queda
// mostrando un conteo desactualizado tras un 403 por límite alcanzado.
const invalidateQueriesMock = vi.fn()

vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => ({
    addSupplier: addSupplierMock,
    updateSupplier: updateSupplierMock,
  }),
}))
vi.mock("@tanstack/react-query", () => ({
  useQueryClient: () => ({ invalidateQueries: invalidateQueriesMock }),
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

// review B (F4): el catch de handleSubmit tragaba cualquier detail del
// backend (403 por límite de plan, 422 por CUIT duplicado, etc.) detrás de
// un "Error al guardar proveedor" genérico — el usuario nunca se enteraba
// de POR QUÉ falló, ni siquiera cuando el backend ya mandaba un mensaje
// perfectamente legible (RFC 7807 detail).
describe("SupplierForm — el catch muestra el mensaje real del backend (F4)", () => {
  afterEach(() => vi.clearAllMocks())

  it("un error con mensaje del backend lo muestra tal cual, no el genérico", async () => {
    addSupplierMock.mockRejectedValueOnce(
      new Error("Límite de proveedores alcanzado para el plan gratis (20 máx.). Borrá proveedores existentes o subí de plan."),
    )
    render(<SupplierForm onSuccess={() => {}} />)
    fireEvent.change(screen.getByLabelText(/nombre/i), { target: { value: "Proveedor 21" } })
    fireEvent.click(screen.getByRole("button", { name: /crear proveedor/i }))

    await vi.waitFor(() => expect(toast.error).toHaveBeenCalledTimes(1))
    expect(toast.error).toHaveBeenCalledWith(
      expect.stringContaining("Límite de proveedores alcanzado"),
    )
  })

  it("TRIANGULATE: un error sin mensaje (no es Error, o message vacío) cae al genérico", async () => {
    addSupplierMock.mockRejectedValueOnce("boom")
    render(<SupplierForm onSuccess={() => {}} />)
    fireEvent.change(screen.getByLabelText(/nombre/i), { target: { value: "Proveedor X" } })
    fireEvent.click(screen.getByRole("button", { name: /crear proveedor/i }))

    await vi.waitFor(() => expect(toast.error).toHaveBeenCalledTimes(1))
    expect(toast.error).toHaveBeenCalledWith("Error al guardar proveedor")
  })

  it("tras un error de alta, invalida queryKeys.suppliers para refrescar el banner de límite", async () => {
    addSupplierMock.mockRejectedValueOnce(new Error("Límite de proveedores alcanzado..."))
    render(<SupplierForm onSuccess={() => {}} />)
    fireEvent.change(screen.getByLabelText(/nombre/i), { target: { value: "Proveedor 21" } })
    fireEvent.click(screen.getByRole("button", { name: /crear proveedor/i }))

    await vi.waitFor(() => expect(toast.error).toHaveBeenCalledTimes(1))
    expect(invalidateQueriesMock).toHaveBeenCalledTimes(1)
  })
})
