/**
 * ProveedorAccountPage (/proveedores/[id]/cuenta):
 * - botón "volver" (compras-proveedor-cuenta-corriente, task 11.5)
 * - qa-integral-modulos (G9): H14 — el encabezado nombra al proveedor (mismo
 *   patrón que ClientDetailHeader); H22 — proveedor sin cuenta corriente
 *   degrada a estado "sin cuenta aún / $0" sin banner destructivo (mismo
 *   trato que ya le da el formulario de compra).
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, act } from "@testing-library/react"
import "@testing-library/jest-dom"

const useSupplierAccountMock = vi.fn()
vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: () => useSupplierAccountMock(),
}))

const useSupplierMock = vi.fn()
vi.mock("@/hooks/data/use-suppliers", () => ({
  useSupplier: () => useSupplierMock(),
}))

vi.mock("@/components/supplier-accounts/SupplierAccountBalance", () => ({
  SupplierAccountBalance: () => null,
}))
vi.mock("@/components/supplier-accounts/SupplierAccountHistory", () => ({
  SupplierAccountHistory: () => null,
}))
vi.mock("@/components/supplier-accounts/RegisterPaymentMadeForm", () => ({
  RegisterPaymentMadeForm: () => null,
}))

import ProveedorAccountPage from "@/app/(dashboard)/proveedores/[id]/cuenta/page"

async function renderPage() {
  const paramsPromise = Promise.resolve({ id: "sup-1" })
  await act(async () => {
    render(
      <React.Suspense fallback={null}>
        <ProveedorAccountPage params={paramsPromise} />
      </React.Suspense>,
    )
    await paramsPromise
  })
}

beforeEach(() => {
  useSupplierAccountMock.mockReset()
  useSupplierAccountMock.mockReturnValue({
    data: { balance: 0, movements: [] },
    isLoading: false,
    error: null,
    refetch: vi.fn(),
  })
  useSupplierMock.mockReset()
  useSupplierMock.mockReturnValue({
    data: { id: "sup-1", name: "Distribuidora Mendoza", email: "", phone: "" },
    isLoading: false,
  })
})

describe("ProveedorAccountPage — navegación de retorno", () => {
  it("el botón 'volver' apunta a /proveedores (no a /compras)", async () => {
    await renderPage()
    const backLink = screen.getByRole("link")
    expect(backLink).toHaveAttribute("href", "/proveedores")
  })
})

describe("ProveedorAccountPage — encabezado con nombre (H14)", () => {
  it("RED 9.4: el título nombra al proveedor, no un genérico 'Cuenta corriente'", async () => {
    await renderPage()
    expect(
      screen.getByRole("heading", { name: /distribuidora mendoza/i }),
    ).toBeInTheDocument()
  })

  it("TRIANGULATE: mientras carga muestra 'Cargando…' y con proveedor irresoluble cae a 'Proveedor'", async () => {
    useSupplierMock.mockReturnValue({ data: undefined, isLoading: true })
    await renderPage()
    expect(screen.getByRole("heading", { name: /cargando/i })).toBeInTheDocument()
  })
})

describe("ProveedorAccountPage — sin cuenta corriente (H22)", () => {
  it("RED 9.5: cuenta inexistente (data null, sin error) degrada a estado 'sin cuenta aún', no banner destructivo", async () => {
    useSupplierAccountMock.mockReturnValue({
      data: null,
      isLoading: false,
      error: null,
      refetch: vi.fn(),
    })
    await renderPage()
    expect(
      screen.getByText(/todavía no tiene movimientos en cuenta corriente/i),
    ).toBeInTheDocument()
    // Sin banner destructivo (el estado NO es un error).
    expect(screen.queryByText(/error al cargar/i)).not.toBeInTheDocument()
  })

  it("TRIANGULATE: un error real sigue mostrando la rama de error", async () => {
    useSupplierAccountMock.mockReturnValue({
      data: undefined,
      isLoading: false,
      error: new Error("Error al cargar la cuenta corriente"),
      refetch: vi.fn(),
    })
    await renderPage()
    expect(screen.getByText(/error al cargar/i)).toBeInTheDocument()
    expect(
      screen.queryByText(/todavía no tiene movimientos/i),
    ).not.toBeInTheDocument()
  })
})
