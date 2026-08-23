/**
 * ProveedorAccountPage (/proveedores/[id]/cuenta) — el botón "volver"
 * (compras-proveedor-cuenta-corriente, task 11.5). D9: la pantalla deja de
 * ser inalcanzable — antes apuntaba a /compras (nunca hubo ruta de origen
 * real), ahora vuelve al listado de proveedores que la enlaza.
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen, act } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("@/hooks/data/use-supplier-account", () => ({
  useSupplierAccount: () => ({
    data: { balance: 0, movements: [] },
    isLoading: false,
    error: null,
    refetch: vi.fn(),
  }),
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

describe("ProveedorAccountPage — navegación de retorno", () => {
  it("el botón 'volver' apunta a /proveedores (no a /compras)", async () => {
    const paramsPromise = Promise.resolve({ id: "sup-1" })
    await act(async () => {
      render(
        <React.Suspense fallback={null}>
          <ProveedorAccountPage params={paramsPromise} />
        </React.Suspense>,
      )
      await paramsPromise
    })
    const backLink = screen.getByRole("link")
    expect(backLink).toHaveAttribute("href", "/proveedores")
  })
})
