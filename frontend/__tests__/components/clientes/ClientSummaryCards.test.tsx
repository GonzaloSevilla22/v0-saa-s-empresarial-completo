/**
 * clientes-frecuentes-historial — TDD tests para ClientSummaryCards
 * (task 8.3 RED / 8.4 GREEN / 8.6).
 *
 * client-purchase-history §"El total comprado es bruto y no descuenta notas
 * de crédito": el rótulo debe ser inequívoco + aclaración + acceso a la
 * cuenta corriente visible desde el resumen.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { ClientSummaryCards } from "@/components/clientes/ClientSummaryCards"
import type { ClientPurchaseSummary } from "@/hooks/data/use-client-activity"

const SUMMARY: ClientPurchaseSummary = {
  purchaseCount: 5,
  totalSpent: 15000.5,
  lastPurchaseDate: "2026-08-01",
  daysSinceLastPurchase: 13,
}

describe("ClientSummaryCards", () => {
  it("renders purchase count, total and last purchase", () => {
    render(<ClientSummaryCards clientId="client-1" summary={SUMMARY} isLoading={false} />)
    expect(screen.getByText("5")).toBeInTheDocument()
    expect(screen.getByText(/13/)).toBeInTheDocument()
  })

  // ── 8.6: rótulo inequívoco + aclaración de NC ────────────────────────────
  it("labels the total as 'Total comprado' and clarifies it does not deduct credit notes", () => {
    render(<ClientSummaryCards clientId="client-1" summary={SUMMARY} isLoading={false} />)
    expect(screen.getByText(/total comprado/i)).toBeInTheDocument()
    expect(screen.getByText(/no descuenta notas de crédito/i)).toBeInTheDocument()
  })

  // ── 8.6: acceso a la cuenta corriente visible desde el resumen ───────────
  it("links to the cuenta corriente tab from the summary", () => {
    render(<ClientSummaryCards clientId="client-1" summary={SUMMARY} isLoading={false} />)
    const link = screen.getByRole("link", { name: /cuenta corriente/i })
    expect(link).toHaveAttribute("href", "/clientes/client-1/cuenta")
  })

  // ── 8.5 TRIANGULATE: cliente sin compras ─────────────────────────────────
  it("shows a friendly message when the client has no purchases", () => {
    render(<ClientSummaryCards
      clientId="client-2"
      summary={{ purchaseCount: 0, totalSpent: 0, lastPurchaseDate: null, daysSinceLastPurchase: null }}
      isLoading={false}
    />)
    expect(screen.getByText(/todavía no compró/i)).toBeInTheDocument()
  })

  // ── 8.5: loading state ────────────────────────────────────────────────────
  it("shows a loading state while the summary is not ready", () => {
    render(<ClientSummaryCards clientId="client-1" summary={null} isLoading />)
    expect(screen.getByTestId("client-summary-loading")).toBeInTheDocument()
  })
})
