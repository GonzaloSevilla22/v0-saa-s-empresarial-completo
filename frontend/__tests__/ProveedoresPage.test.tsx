/**
 * ProveedoresPage — listado + alta/edición + baja + acceso a cuenta corriente
 * (compras-proveedor-cuenta-corriente, task 11.3/11.6). Molde de ClientesPage,
 * con menos columnas (D9: sin read-model de actividad — OQ-6 fuera de alcance).
 *
 * Ciclo: RED → GREEN → TRIANGULATE (listado vacío / con resultados / búsqueda
 * sin resultados / límite de plan alcanzado — task 11.6).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"

const pushMock = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
}))

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}))

const deleteSupplierMock = vi.fn().mockResolvedValue(undefined)
const useSuppliersMock = vi.fn()
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSuppliers: () => useSuppliersMock(),
}))

const usePlanLimitsMock = vi.fn()
vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => usePlanLimitsMock(),
}))

// SupplierForm ya tiene su propia cobertura (__tests__/components/supplier-form.test.tsx)
// — acá se mockea para verificar SOLO que la página lo monta con el
// initialData correcto en modo edición.
vi.mock("@/components/forms/supplier-form", () => ({
  SupplierForm: ({ initialData }: { initialData?: { name: string } }) => (
    <div data-testid="supplier-form-stub">{initialData?.name ?? "alta"}</div>
  ),
}))

import ProveedoresPage from "@/app/(dashboard)/proveedores/page"

const SUPPLIERS = [
  { id: "sup-1", name: "Distribuidora Mendoza", email: "contacto@dm.com", phone: "2615551234" },
  { id: "sup-2", name: "Envases del Oeste", email: "ventas@envases.com", phone: "" },
]

function defaultSuppliersReturn(overrides: Partial<ReturnType<typeof useSuppliersMock>> = {}) {
  return {
    suppliers: SUPPLIERS,
    isLoading: false,
    isError: false,
    error: null,
    deleteSupplier: deleteSupplierMock,
    ...overrides,
  }
}

describe("ProveedoresPage", () => {
  beforeEach(() => {
    pushMock.mockReset()
    deleteSupplierMock.mockClear()
    useSuppliersMock.mockReset()
    useSuppliersMock.mockReturnValue(defaultSuppliersReturn())
    usePlanLimitsMock.mockReset()
    usePlanLimitsMock.mockReturnValue({ limits: { maxSuppliers: 20 } })
  })

  it("renders each supplier row with name and contact", () => {
    render(<ProveedoresPage />)
    expect(screen.getAllByText("Distribuidora Mendoza").length).toBeGreaterThan(0)
    expect(screen.getAllByText("Envases del Oeste").length).toBeGreaterThan(0)
  })

  it("TRIANGULATE: la búsqueda filtra por nombre", () => {
    render(<ProveedoresPage />)
    const search = screen.getByPlaceholderText(/buscar/i)
    fireEvent.change(search, { target: { value: "Mendoza" } })
    expect(screen.getAllByText("Distribuidora Mendoza").length).toBeGreaterThan(0)
    expect(screen.queryByText("Envases del Oeste")).not.toBeInTheDocument()
  })

  it("TRIANGULATE: búsqueda sin resultados muestra el mensaje correspondiente", () => {
    render(<ProveedoresPage />)
    const search = screen.getByPlaceholderText(/buscar/i)
    fireEvent.change(search, { target: { value: "no existe" } })
    expect(screen.getByText(/sin resultados para esa búsqueda/i)).toBeInTheDocument()
  })

  it("TRIANGULATE: listado vacío muestra el empty state con CTA", () => {
    useSuppliersMock.mockReturnValue(defaultSuppliersReturn({ suppliers: [] }))
    render(<ProveedoresPage />)
    expect(screen.getByText(/no hay proveedores registrados/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /agregar primer proveedor/i })).toBeInTheDocument()
  })

  it("TRIANGULATE: alcanzar el límite del plan deshabilita 'Nuevo proveedor' y muestra el banner", () => {
    usePlanLimitsMock.mockReturnValue({ limits: { maxSuppliers: 2 } })
    render(<ProveedoresPage />)
    expect(screen.getByText(/límite de 2 proveedores/i)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: /nuevo proveedor/i })).toBeDisabled()
  })

  it("bajo el límite, 'Nuevo proveedor' está habilitado y sin banner", () => {
    render(<ProveedoresPage />)
    expect(screen.queryByText(/límite de/i)).not.toBeInTheDocument()
    expect(screen.getByRole("button", { name: /nuevo proveedor/i })).not.toBeDisabled()
  })

  it("clicking 'Nuevo proveedor' abre el diálogo en modo alta", () => {
    render(<ProveedoresPage />)
    fireEvent.click(screen.getByRole("button", { name: /nuevo proveedor/i }))
    expect(screen.getByTestId("supplier-form-stub")).toHaveTextContent("alta")
  })

  it("clicking editar abre el diálogo con el proveedor precargado", () => {
    render(<ProveedoresPage />)
    const [editBtn] = screen.getAllByTestId("supplier-edit-sup-1")
    fireEvent.click(editBtn)
    expect(screen.getByTestId("supplier-form-stub")).toHaveTextContent("Distribuidora Mendoza")
  })

  it("clicking la acción de cuenta corriente navega a /proveedores/{id}/cuenta", () => {
    render(<ProveedoresPage />)
    const [accountBtn] = screen.getAllByTestId("supplier-account-sup-1")
    fireEvent.click(accountBtn)
    expect(pushMock).toHaveBeenCalledWith("/proveedores/sup-1/cuenta")
  })

  it("baja con confirmación: borrar dispara el diálogo, y confirmar llama a deleteSupplier", async () => {
    render(<ProveedoresPage />)
    const [deleteBtn] = screen.getAllByTestId("supplier-delete-sup-1")
    fireEvent.click(deleteBtn)

    const confirmBtn = await screen.findByRole("button", { name: /^eliminar$/i })
    fireEvent.click(confirmBtn)

    await vi.waitFor(() => expect(deleteSupplierMock).toHaveBeenCalledWith("sup-1"))
  })
})
