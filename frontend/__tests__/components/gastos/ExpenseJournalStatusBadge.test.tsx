/**
 * asiento-contable-gastos (D9, task 9.3) — TDD tests para
 * ExpenseJournalStatusBadge.
 *
 * El estado NO SHALL comunicarse únicamente por color, y "pendiente" /
 * "sin_asiento" NO SHALL usar el tono de error (spec expense-journal-entry
 * §"El estado contable del gasto es visible en la superficie de gastos").
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import {
  ExpenseJournalStatusBadge,
  deriveExpenseJournalStatus,
} from "@/components/gastos/ExpenseJournalStatusBadge"

describe("deriveExpenseJournalStatus", () => {
  it("asentado cuando hay asiento vigente", () => {
    expect(deriveExpenseJournalStatus({ hasJournalEntry: true, journalPending: false })).toBe("asentado")
  })
  it("pendiente cuando hay evento sin procesar", () => {
    expect(deriveExpenseJournalStatus({ hasJournalEntry: false, journalPending: true })).toBe("pendiente")
  })
  it("sin_asiento cuando no hay ni asiento ni evento (histórico)", () => {
    expect(deriveExpenseJournalStatus({ hasJournalEntry: false, journalPending: false })).toBe("sin_asiento")
  })
  it("journalPending prevalece sobre hasJournalEntry (F2, revisor adversarial, opción a): un gasto recién editado muestra 'pendiente' mientras su ExpenseAdjusted no se despachó, aunque el asiento anterior siga vigente", () => {
    expect(deriveExpenseJournalStatus({ hasJournalEntry: true, journalPending: true })).toBe("pendiente")
  })
})

describe("ExpenseJournalStatusBadge", () => {
  it("renders visible text for asentado", () => {
    render(<ExpenseJournalStatusBadge expenseId="e1" hasJournalEntry />)
    expect(screen.getByText(/asentado/i)).toBeInTheDocument()
  })

  it("renders visible text for pendiente", () => {
    render(<ExpenseJournalStatusBadge expenseId="e1" journalPending />)
    expect(screen.getByText(/pendiente/i)).toBeInTheDocument()
  })

  it("renders visible text for sin_asiento", () => {
    render(<ExpenseJournalStatusBadge expenseId="e1" />)
    expect(screen.getByText(/sin asiento/i)).toBeInTheDocument()
  })

  it("never uses a literal Tailwind color class — only semantic tokens", () => {
    const { container: a } = render(<ExpenseJournalStatusBadge expenseId="e1" hasJournalEntry />)
    const { container: b } = render(<ExpenseJournalStatusBadge expenseId="e1" journalPending />)
    const { container: c } = render(<ExpenseJournalStatusBadge expenseId="e1" />)
    for (const html of [a.innerHTML, b.innerHTML, c.innerHTML]) {
      expect(html).not.toMatch(/emerald-|yellow-|red-|amber-|green-\d/)
    }
  })

  it("pendiente y sin_asiento NO usan el tono de error (destructive)", () => {
    const { container: pendiente } = render(<ExpenseJournalStatusBadge expenseId="e1" journalPending />)
    const { container: sinAsiento } = render(<ExpenseJournalStatusBadge expenseId="e1" />)
    expect(pendiente.innerHTML).not.toMatch(/destructive/)
    expect(sinAsiento.innerHTML).not.toMatch(/destructive/)
  })

  it("asentado enlaza al libro diario filtrado por el gasto (source_doc_ref)", () => {
    render(<ExpenseJournalStatusBadge expenseId="expense-42" hasJournalEntry />)
    const link = screen.getByRole("link", { name: /asentado/i })
    expect(link).toHaveAttribute("href", "/reportes/libro-diario?source_doc_type=Expense&source_doc_ref=expense-42")
  })

  it("pendiente y sin_asiento NO son un enlace — no prometen un destino", () => {
    render(<ExpenseJournalStatusBadge expenseId="e1" journalPending />)
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
  })

  it("F2: pendiente CON hasJournalEntry (edición recién hecha, ExpenseAdjusted sin despachar) sigue enlazando al asiento vigente anterior", () => {
    render(<ExpenseJournalStatusBadge expenseId="expense-42" hasJournalEntry journalPending />)
    expect(screen.getByText(/^pendiente$/i)).toBeInTheDocument()
    const link = screen.getByRole("link", { name: /pendiente/i })
    expect(link).toHaveAttribute("href", "/reportes/libro-diario?source_doc_type=Expense&source_doc_ref=expense-42")
  })

  it("el título de pendiente comunica espera, no error", () => {
    render(<ExpenseJournalStatusBadge expenseId="e1" journalPending />)
    const el = screen.getByTestId("expense-journal-status")
    expect(el.getAttribute("title")).toMatch(/en unos minutos/i)
  })

  it("el título de sin_asiento explica que es anterior, no un fallo", () => {
    render(<ExpenseJournalStatusBadge expenseId="e1" />)
    const el = screen.getByTestId("expense-journal-status")
    expect(el.getAttribute("title")).toMatch(/anterior/i)
  })
})
