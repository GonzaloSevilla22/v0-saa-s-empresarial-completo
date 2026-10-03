/**
 * remitos-venta (D11, tarea 5.8) — la ficha del cliente suma "Nuevo remito"
 * (`/remitos/nuevo?cliente=<id>`, sólo con `CAN_DELIVER_SALE`) y "Ver remitos"
 * (`/remitos?cliente=<id>`, el contrato de query params de D11, para cualquier
 * miembro) en `ClientDetailHeader`.
 *
 * En móvil la cabecera ya usa botones de sólo ícono: los dos nuevos llevan
 * `aria-label` DISTINTOS entre sí y de "Nuevo presupuesto" (sin él serían tres
 * botones mudos), y el título conserva su `min-w-0` para no desbordar a 375 px.
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({ useOrgRole: vi.fn() }))

vi.mock("next/navigation", () => ({ usePathname: () => "/clientes/client-1" }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClient: () => ({ data: { id: "client-1", name: "Acme Corp", email: "", phone: "" }, isLoading: false }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))

import { ClientDetailHeader } from "@/components/clientes/ClientDetailHeader"

function setRoles(roles: string[], rolesResolved = true) {
  mocks.useOrgRole.mockReturnValue({ role: "member", roles, rolesResolved, isWriter: false, isLoading: false })
}

beforeEach(() => {
  vi.clearAllMocks()
  setRoles(["owner"])
})

describe("ClientDetailHeader — remitos", () => {
  it("'Nuevo remito' lleva a /remitos/nuevo con el cliente preseleccionado", () => {
    render(<ClientDetailHeader clientId="client-1" />)
    expect(screen.getByRole("link", { name: "Nuevo remito" })).toHaveAttribute("href", "/remitos/nuevo?cliente=client-1")
  })

  it("'Ver remitos' lleva al listado filtrado por cliente (contrato ?cliente= de D11)", () => {
    render(<ClientDetailHeader clientId="client-1" />)
    expect(screen.getByRole("link", { name: "Ver remitos" })).toHaveAttribute("href", "/remitos?cliente=client-1")
  })

  it("el id del cliente se escapa en las dos URLs", () => {
    render(<ClientDetailHeader clientId="a b&c" />)
    expect(screen.getByRole("link", { name: "Nuevo remito" })).toHaveAttribute("href", "/remitos/nuevo?cliente=a%20b%26c")
    expect(screen.getByRole("link", { name: "Ver remitos" })).toHaveAttribute("href", "/remitos?cliente=a%20b%26c")
  })

  it.each([
    [["owner"], true],
    [["admin"], true],
    [["seller"], true],
    [["stock"], true],
    [["cashier"], false],
    [["viewer"], false],
    [["accountant"], false],
    [["purchases"], false],
  ])("con roles %j 'Nuevo remito' visible=%s y 'Ver remitos' siempre se ve", (roles, visible) => {
    setRoles(roles)
    render(<ClientDetailHeader clientId="client-1" />)
    expect(!!screen.queryByRole("link", { name: "Nuevo remito" })).toBe(visible)
    expect(screen.getByRole("link", { name: "Ver remitos" })).toBeInTheDocument()
  })

  it("'Nuevo presupuesto' sigue decidiéndose por su propia capacidad (un encargado de stock no presupuesta)", () => {
    setRoles(["stock"])
    render(<ClientDetailHeader clientId="client-1" />)
    expect(screen.queryByRole("link", { name: "Nuevo presupuesto" })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Nuevo remito" })).toBeInTheDocument()
  })

  it("los tres botones tienen nombre accesible propio y distinto (en móvil son sólo ícono)", () => {
    render(<ClientDetailHeader clientId="client-1" />)
    const names = ["Nuevo presupuesto", "Nuevo remito", "Ver remitos"].map((name) =>
      screen.getByRole("link", { name }).getAttribute("aria-label"),
    )
    expect(names).toEqual(["Nuevo presupuesto", "Nuevo remito", "Ver remitos"])
    expect(new Set(names).size).toBe(3)
  })

  it("el título conserva min-w-0 y truncate para que los botones nuevos no lo desborden a 375 px", () => {
    render(<ClientDetailHeader clientId="client-1" />)
    const title = screen.getByRole("heading", { name: "Acme Corp" })
    expect(title.className).toContain("truncate")
    expect(title.parentElement?.className).toContain("min-w-0")
  })

  it("las pestañas existentes no cambian (no se agrega una pestaña de remitos)", () => {
    render(<ClientDetailHeader clientId="client-1" />)
    const tabs = screen.getByRole("navigation", { name: /secciones del cliente/i })
    expect(tabs.querySelectorAll("a")).toHaveLength(3)
    expect(tabs).not.toHaveTextContent(/remitos/i)
  })
})
