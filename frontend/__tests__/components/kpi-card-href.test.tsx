/**
 * KpiCard — prop `href` opcional (cobranzas-panel, task 5.7 / D7).
 *
 * La tarjeta enlazada se convierte en un enlace con foco visible y área
 * clickeable completa; las tarjetas existentes que NO pasan href conservan
 * exactamente su comportamiento (sin <a>, sin tabIndex).
 */

import React from "react"
import { describe, it, expect, vi } from "vitest"
import { render, screen } from "@testing-library/react"
import "@testing-library/jest-dom"
import { DollarSign } from "lucide-react"

vi.mock("next/link", () => ({
  default: ({ href, children, className }: { href: string; children: React.ReactNode; className?: string }) => (
    <a href={href} className={className}>
      {children}
    </a>
  ),
}))

import { KpiCard } from "@/components/dashboard/kpi-card"

describe("KpiCard — prop href (D7)", () => {
  it("sin href renderiza la tarjeta sin enlace (las 4 tarjetas existentes)", () => {
    render(<KpiCard title="Ventas hoy" value="$100" icon={DollarSign} />)
    expect(screen.getByText("Ventas hoy")).toBeInTheDocument()
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
  })

  it("con href la tarjeta entera es un enlace hacia el destino", () => {
    render(
      <KpiCard title="Por cobrar" value="$567.000" icon={DollarSign} href="/cobranzas" />,
    )
    const link = screen.getByRole("link")
    expect(link).toHaveAttribute("href", "/cobranzas")
    expect(link).toHaveTextContent("Por cobrar")
    expect(link).toHaveTextContent("$567.000")
  })

  it("el enlace declara foco visible (focus-visible:ring)", () => {
    render(
      <KpiCard title="Por cobrar" value="$1" icon={DollarSign} href="/cobranzas" />,
    )
    expect(screen.getByRole("link").className).toMatch(/focus-visible:/)
  })
})
