/**
 * Importador de gastos — D13 / tasks 11.7 y 11.8.
 *
 * El importador llama `addExpense` UNA VEZ POR FILA, sin ninguna transacción
 * que abarque el loop: con impacto en libros, importar 200 filas generaría 200
 * movimientos y, ante un fallo a mitad de camino, dejaría N gastos con
 * movimiento y M sin — un descuadre imposible de reconstruir. Por eso las
 * filas importadas entran SIN forma de pago, y el texto del paso 1 tiene que
 * decir la verdad completa: imputarles la forma de pago después desde el
 * listado es sólo una etiqueta, porque la EDICIÓN no postea movimientos
 * (`rpc_update_expense` ni siquiera recibe `p_cash_session_id` /
 * `p_bank_account_id`). La redacción anterior del design prometía un efecto
 * que el sistema no produce y quedó explícitamente prohibida.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent } from "@testing-library/react"

const addExpenseMock = vi.fn().mockResolvedValue(undefined)
// El importador usa el alta MASIVA (sin invalidación por fila): ver
// expense-import-dialog-invalidation.test.tsx.
vi.mock("@/hooks/data/use-expenses-query", () => ({
  useBulkAddExpense: () => ({
    addExpenseMutation: { mutateAsync: addExpenseMock },
    invalidateLedgers: vi.fn(),
  }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }))

import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"

const CSV = [
  "Descripción;Categoría;Monto;Fecha",
  "Alquiler del local;Alquiler;150000;2026-08-01",
  "Factura de luz;Servicios;12000;2026-08-05",
].join("\n")

beforeEach(() => {
  vi.clearAllMocks()
})

async function uploadCsv() {
  const input = document.getElementById("csv-expense-upload") as HTMLInputElement
  const file = new File([CSV], "gastos.csv", { type: "text/csv" })
  fireEvent.change(input, { target: { files: [file] } })
  // El paso 2 aparece cuando el FileReader terminó de parsear.
  await waitFor(() => expect(screen.getByRole("button", { name: /importar 2 gastos/i })).toBeInTheDocument())
}

describe("ExpenseImportDialog — 11.7: el texto del paso 1 dice la verdad", () => {
  it("declara que los gastos importados no impactan caja ni banco, y que imputarlos después es sólo una etiqueta", () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    const text = document.body.textContent ?? ""
    expect(text).toMatch(/sin forma de pago y sin impacto en caja ni en banco/i)
    expect(text).toMatch(/s[oó]lo una etiqueta/i)
    expect(text).toMatch(/cargarlo desde el formulario/i)
  })

  it("NO promete que imputar después haga impactar los libros (redacción prohibida por D13)", () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    const text = document.body.textContent ?? ""
    expect(text).not.toMatch(/imputalos despu[eé]s desde el listado si quer[eé]s que impacten/i)
  })
})

describe("ExpenseImportDialog — 11.8: el payload no lleva forma de pago", () => {
  it("importa las filas sin payment_method_id, sin sesión de caja y sin cuenta bancaria", async () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    await uploadCsv()

    fireEvent.click(screen.getByRole("button", { name: /importar 2 gastos/i }))

    await waitFor(() => expect(addExpenseMock).toHaveBeenCalledTimes(2))
    for (const [payload] of addExpenseMock.mock.calls) {
      expect("paymentMethodId" in payload).toBe(false)
      expect("cashSessionId" in payload).toBe(false)
      expect("bankAccountId" in payload).toBe(false)
    }
    // Control positivo: lo que SÍ importa sigue viajando — si el payload
    // llegara vacío, las tres aserciones de arriba pasarían igual.
    expect(addExpenseMock.mock.calls[0][0]).toMatchObject({
      description: "Alquiler del local",
      category: "Alquiler",
      amount: 150000,
    })
  })
})
