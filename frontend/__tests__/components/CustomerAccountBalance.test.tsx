/**
 * Candidato heredado de `cobranzas-panel` (D14, ver CLAUDE.md
 * §"Candidatos para el próximo /opsx:propose"): CustomerAccountBalance usaba
 * `text-yellow-400` / `text-emerald-400` / `bg-yellow-500/10` /
 * `bg-emerald-500/10` literales para "deuda" / "a favor" en vez de los
 * tokens semánticos que el resto de las superficies de dinero ya usa
 * (`text-warning` / `text-success`, ver sale-operations-list.tsx,
 * cart-item-list.tsx). Este test es el RED de ese hallazgo: assertea la
 * clase aplicada (token, no color literal) para saldo deudor y acreedor, y
 * que ningún color literal sobreviva en el DOM renderizado.
 */
import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"

import { CustomerAccountBalance } from "@/components/customer-accounts/CustomerAccountBalance"

describe("CustomerAccountBalance — tokens semánticos (no colores literales)", () => {
  it("saldo deudor (balance > 0) usa el token warning, nunca yellow-400", () => {
    render(<CustomerAccountBalance balance={15000} />)

    const amount = screen.getByText("$ 15.000,00")
    expect(amount.className).toMatch(/\btext-warning\b/)
    expect(amount.className).not.toMatch(/yellow-400/)

    const label = screen.getByText("Debe al negocio")
    expect(label).toBeInTheDocument()
  })

  it("saldo a favor (balance < 0) usa el token success, nunca emerald-400", () => {
    render(<CustomerAccountBalance balance={-8000} />)

    const amount = screen.getByText("-$ 8.000,00")
    expect(amount.className).toMatch(/\btext-success\b/)
    expect(amount.className).not.toMatch(/emerald-400/)

    const label = screen.getByText("Saldo a favor del cliente")
    expect(label).toBeInTheDocument()
  })

  it("saldo cero usa foreground neutro, sin ningún token de color ni literal", () => {
    render(<CustomerAccountBalance balance={0} />)

    const amount = screen.getByText("$ 0,00")
    expect(amount.className).toMatch(/\btext-foreground\b/)
    expect(amount.className).not.toMatch(/text-warning|text-success|yellow-400|emerald-400/)
  })

  it("ningún color literal (yellow-*/emerald-*) sobrevive en el árbol renderizado, en ningún estado", () => {
    const { container: debt } = render(<CustomerAccountBalance balance={15000} />)
    expect(debt.innerHTML).not.toMatch(/yellow-400|yellow-500|emerald-400|emerald-500/)

    const { container: credit } = render(<CustomerAccountBalance balance={-8000} />)
    expect(credit.innerHTML).not.toMatch(/yellow-400|yellow-500|emerald-400|emerald-500/)
  })
})
