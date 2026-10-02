/**
 * presupuestos-modulo (D10, tarea 5.10) — cabecera de la ficha del cliente:
 *  - botón "Nuevo presupuesto" -> `/presupuestos/nuevo?cliente=<id>`, visible en
 *    TODAS las pestañas y sólo con `CAN_QUOTE` (conjunto de roles);
 *  - tercera pestaña "Presupuestos"; la pestaña activa se decide comparando la
 *    ruta de cada una (antes: `isHistorialActive = !isCuentaActive`, que con tres
 *    pestañas marcaría "Historial" también sobre "Presupuestos").
 */
import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"

const mocks = vi.hoisted(() => ({ pathname: { value: "/clientes/client-1" }, useOrgRole: vi.fn() }))

vi.mock("next/navigation", () => ({ usePathname: () => mocks.pathname.value }))
vi.mock("@/hooks/data/use-clients", () => ({
  useClient: () => ({ data: { id: "client-1", name: "Acme Corp", email: "", phone: "2615551234" }, isLoading: false }),
}))
vi.mock("@/hooks/useOrgRole", () => ({ useOrgRole: () => mocks.useOrgRole() }))

import { ClientDetailHeader } from "@/components/clientes/ClientDetailHeader"

function asRoles(roles: string[], resolved = true) {
  mocks.useOrgRole.mockReturnValue({ role: roles[0], roles, rolesResolved: resolved, isWriter: true, isLoading: false })
}

const TABS: Array<[string, string, string]> = [
  ["Historial de compras", "/clientes/client-1", "/clientes/client-1"],
  ["Cuenta corriente", "/clientes/client-1/cuenta", "/clientes/client-1/cuenta"],
  ["Presupuestos", "/clientes/client-1/presupuestos", "/clientes/client-1/presupuestos"],
]

beforeEach(() => {
  mocks.pathname.value = "/clientes/client-1"
  asRoles(["owner"])
})

describe("ClientDetailHeader — pestañas", () => {
  it("ofrece las tres pestañas, cada una con su ruta", () => {
    render(<ClientDetailHeader clientId="client-1" />)

    for (const [name, href] of TABS) {
      expect(screen.getByRole("link", { name })).toHaveAttribute("href", href)
    }
  })

  it.each(TABS)("sobre la ruta de «%s» ella es la única activa", (activeName, _href, pathname) => {
    mocks.pathname.value = pathname
    render(<ClientDetailHeader clientId="client-1" />)

    for (const [name] of TABS) {
      const link = screen.getByRole("link", { name })
      if (name === activeName) expect(link).toHaveAttribute("aria-current", "page")
      else expect(link).not.toHaveAttribute("aria-current")
    }
  })

  it("una ruta que no es ninguna de las tres no deja a «Historial» marcada por descarte", () => {
    mocks.pathname.value = "/clientes/client-1/otra-cosa"
    render(<ClientDetailHeader clientId="client-1" />)

    for (const [name] of TABS) {
      expect(screen.getByRole("link", { name })).not.toHaveAttribute("aria-current")
    }
  })
})

describe("ClientDetailHeader — Nuevo presupuesto", () => {
  it.each(TABS)("el botón está en la pestaña «%s» y lleva al alta con el cliente preseleccionado", (_name, _href, pathname) => {
    mocks.pathname.value = pathname
    render(<ClientDetailHeader clientId="client-1" />)

    expect(screen.getByRole("link", { name: /nuevo presupuesto/i })).toHaveAttribute(
      "href",
      "/presupuestos/nuevo?cliente=client-1",
    )
  })

  it("un usuario sólo seller lo ve", () => {
    asRoles(["seller"])
    render(<ClientDetailHeader clientId="client-1" />)

    expect(screen.getByRole("link", { name: /nuevo presupuesto/i })).toBeInTheDocument()
  })

  it("un usuario sólo cashier no lo ve (la ficha sigue igual)", () => {
    asRoles(["cashier"])
    render(<ClientDetailHeader clientId="client-1" />)

    expect(screen.queryByRole("link", { name: /nuevo presupuesto/i })).not.toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Historial de compras" })).toBeInTheDocument()
  })

  it("mientras los roles no resolvieron se muestra (fail-open)", () => {
    asRoles(["member"], false)
    render(<ClientDetailHeader clientId="client-1" />)

    expect(screen.getByRole("link", { name: /nuevo presupuesto/i })).toBeInTheDocument()
  })

  it("conserva la identificación del cliente en la cabecera", () => {
    render(<ClientDetailHeader clientId="client-1" />)

    expect(screen.getByRole("heading", { name: "Acme Corp" })).toBeInTheDocument()
  })
})

describe("ClientDetailHeader — pestañas en móvil (hallazgo de la pasada visual 7.3)", () => {
  // Con la tercera pestaña, el riel con `whitespace-nowrap` medía 401 px dentro de
  // 343: "Presupuestos" quedaba cortada ("Presup") detrás de un scroll horizontal.
  // En móvil las pestañas se reparten el ancho y pueden partir el rótulo en dos
  // líneas; desde `sm` vuelven a su ancho natural en una sola línea.
  it("cada pestaña se reparte el ancho y puede partir el rótulo en móvil", () => {
    render(<ClientDetailHeader clientId="client-1" />)

    for (const [name] of TABS) {
      const tokens = screen.getByRole("link", { name }).className.split(/\s+/)
      expect(tokens).toContain("flex-1")
      expect(tokens).toContain("whitespace-normal")
      expect(tokens).toContain("sm:flex-none")
      expect(tokens).toContain("sm:whitespace-nowrap")
      expect(tokens).not.toContain("whitespace-nowrap")
    }
  })

  it("la pestaña activa conserva su subrayado y la inactiva no", () => {
    mocks.pathname.value = "/clientes/client-1/presupuestos"
    render(<ClientDetailHeader clientId="client-1" />)

    expect(screen.getByRole("link", { name: "Presupuestos" }).className).toContain("border-primary")
    expect(screen.getByRole("link", { name: "Cuenta corriente" }).className).toContain("border-transparent")
  })
})
