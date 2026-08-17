/**
 * clientes-frecuentes-historial — TDD tests para ClientActivityBadge
 * (task 7.1 RED / 7.2 GREEN).
 *
 * client-activity §"Señalización de actividad en la lista de clientes": el
 * estado NO SHALL comunicarse únicamente por color — cada badge debe
 * renderizar texto visible para sus 4 estados.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { ClientActivityBadge } from "@/components/clientes/ClientActivityBadge"

describe("ClientActivityBadge", () => {
  it("renders visible text for frecuente", () => {
    render(<ClientActivityBadge status="frecuente" />)
    expect(screen.getByText(/frecuente/i)).toBeInTheDocument()
  })

  it("renders visible text for activo", () => {
    render(<ClientActivityBadge status="activo" />)
    expect(screen.getByText(/activo/i)).toBeInTheDocument()
  })

  it("renders visible text for inactivo", () => {
    render(<ClientActivityBadge status="inactivo" />)
    expect(screen.getByText(/inactivo/i)).toBeInTheDocument()
  })

  it("renders visible text for sin_compras", () => {
    render(<ClientActivityBadge status="sin_compras" />)
    expect(screen.getByText(/sin compras/i)).toBeInTheDocument()
  })

  it("never uses a literal Tailwind color class — only semantic tokens", () => {
    const { container } = render(<ClientActivityBadge status="inactivo" />)
    const html = container.innerHTML
    expect(html).not.toMatch(/emerald-|yellow-|red-|amber-/)
  })
})
