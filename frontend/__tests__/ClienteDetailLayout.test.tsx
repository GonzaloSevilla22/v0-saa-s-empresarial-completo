/**
 * clientes-frecuentes-historial — TDD tests para
 * frontend/app/(dashboard)/clientes/[id]/layout.tsx (task 8.1).
 *
 * client-purchase-history §"Superficie de detalle del cliente con pestañas":
 * cabecera con la identificación del cliente + navegación por pestañas entre
 * "Historial de compras" y "Cuenta corriente", cada una enlazable.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

vi.mock("next/navigation", () => ({
  usePathname: () => "/clientes/client-1",
}))

const useClientMock = vi.fn()
vi.mock("@/hooks/data/use-clients", () => ({
  useClient: (id: string | null) => useClientMock(id),
}))

import ClienteDetailLayout from "@/app/(dashboard)/clientes/[id]/layout"

describe("ClienteDetailLayout", () => {
  beforeEach(() => {
    useClientMock.mockReset()
    useClientMock.mockReturnValue({
      data: { id: "client-1", name: "Acme Corp" },
      isLoading: false,
    })
  })

  it("renders the client's name in the header", async () => {
    render(
      await ClienteDetailLayout({
        params: Promise.resolve({ id: "client-1" }),
        children: <div>contenido</div>,
      } as any)
    )
    expect(screen.getByText("Acme Corp")).toBeInTheDocument()
  })

  it("renders both tabs linking to the historial and cuenta corriente routes", async () => {
    render(
      await ClienteDetailLayout({
        params: Promise.resolve({ id: "client-1" }),
        children: <div>contenido</div>,
      } as any)
    )
    const historialTab = screen.getByRole("link", { name: /historial de compras/i })
    const cuentaTab = screen.getByRole("link", { name: /cuenta corriente/i })
    expect(historialTab).toHaveAttribute("href", "/clientes/client-1")
    expect(cuentaTab).toHaveAttribute("href", "/clientes/client-1/cuenta")
  })

  it("marks the historial tab as active on the /clientes/[id] route", async () => {
    render(
      await ClienteDetailLayout({
        params: Promise.resolve({ id: "client-1" }),
        children: <div>contenido</div>,
      } as any)
    )
    const historialTab = screen.getByRole("link", { name: /historial de compras/i })
    expect(historialTab).toHaveAttribute("aria-current", "page")
  })

  it("renders the children content", async () => {
    render(
      await ClienteDetailLayout({
        params: Promise.resolve({ id: "client-1" }),
        children: <div>contenido de la pestaña</div>,
      } as any)
    )
    expect(screen.getByText("contenido de la pestaña")).toBeInTheDocument()
  })
})
