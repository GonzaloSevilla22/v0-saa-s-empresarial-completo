/**
 * Importador de gastos — importador-gastos-transaccional (D13 del design,
 * task 8.9): esta suite REEMPLAZA la anterior, que fijaba el comportamiento
 * VIEJO ("los gastos importados quedan sin forma de pago y sin impacto en
 * caja ni en banco"). Ese comportamiento era una consecuencia de una
 * LIMITACIÓN TÉCNICA —el importador emitía una llamada por fila sin
 * transacción de lote— que este change elimina: el lote pasa a ser una sola
 * transacción de servidor (`rpc_import_expenses`) que SÍ acepta forma de
 * pago, sucursal y centro de costo, resueltos por NOMBRE.
 *
 * Qué se INVIERTE (documentado por escrito, D13/task 2.4):
 *   - el payload YA NO omite `payment_method_name`/`branch_name`/
 *     `cost_center_name` — viajan tal cual la celda del CSV;
 *   - el texto del paso 1 ya NO promete "sin impacto en caja ni en banco":
 *     la pata bancaria SÍ se registra; sólo la de CAJA sigue sin impacto.
 *
 * Qué se CONSERVA como aserción PERMANENTE (D6, nunca se relaja):
 *   - el payload de la mutación NUNCA lleva una sesión de caja — el lote no
 *     tiene ese campo ni por construcción (el tipo `ExpenseImportInput` no
 *     lo declara), y este test lo re-verifica explícitamente contra el
 *     payload REAL que llega al hook.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent } from "@testing-library/react"

const importMock = vi.fn()
const invalidateLedgersMock = vi.fn()

vi.mock("@/hooks/data/use-expenses-query", () => ({
  useImportExpenses: () => ({
    importMutation: { mutateAsync: importMock },
    invalidateLedgers: invalidateLedgersMock,
  }),
}))
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn(), info: vi.fn(), warning: vi.fn() } }))
vi.mock("@/lib/bank-statement-parser", () => ({
  hashFileSHA256: vi.fn().mockResolvedValue("hash-fixed-for-test"),
}))
// Selectores canónicos: se mockean a null para aislar el comportamiento del
// diálogo de su implementación (se reusan tal cual, no se reescriben — D10).
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))

import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"

const CSV = [
  "Descripción;Categoría;Monto;Fecha;Forma de pago;Sucursal;Centro de costo",
  "Alquiler del local;Alquiler;150000;2026-08-01;Transferencia bancaria;;",
  "Factura de luz;Servicios;12000;2026-08-05;;;",
].join("\n")

function applyDryRunResult(overrides: Partial<Record<string, unknown>> = {}) {
  return {
    committed: false,
    importId: null,
    imported: 2,
    errors: [],
    notices: [],
    replayed: false,
    dryRun: true,
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  importMock.mockResolvedValue(applyDryRunResult())
})

async function uploadCsv() {
  const input = document.getElementById("csv-expense-upload") as HTMLInputElement
  const file = new File([CSV], "gastos.csv", { type: "text/csv" })
  fireEvent.change(input, { target: { files: [file] } })
  // El paso 2 dispara la SIMULACIÓN automáticamente al entrar (D9) — se
  // espera a que la mutación de dry-run se haya llamado.
  await waitFor(() => expect(importMock).toHaveBeenCalled())
}

describe("ExpenseImportDialog — el texto del paso 1 dice la verdad (D13, invertido)", () => {
  it("declara que el lote es todo o nada y que el efectivo no impacta la caja", () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    const text = document.body.textContent ?? ""
    expect(text).toMatch(/todo o nada/i)
    expect(text).toMatch(/efectivo.*no impactan la caja|no impactan la caja/i)
    expect(text).toMatch(/cargalo desde el formulario/i)
  })

  it("NO promete 'sin impacto en caja ni en banco' — la pata bancaria SÍ se registra (redacción prohibida por D13)", () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    const text = document.body.textContent ?? ""
    expect(text).not.toMatch(/sin impacto en caja ni en banco/i)
    expect(text).not.toMatch(/quedan sin forma de pago/i)
  })
})

describe("ExpenseImportDialog — el payload SÍ lleva forma de pago/sucursal/centro de costo por nombre", () => {
  it("las filas viajan con payment_method_name/branch_name resueltos desde la celda cruda del CSV", async () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    await uploadCsv()

    const dryRunCall = importMock.mock.calls[0][0]
    expect(dryRunCall.dryRun).toBe(true)
    expect(dryRunCall.rows).toHaveLength(2)
    expect(dryRunCall.rows[0]).toMatchObject({
      description: "Alquiler del local",
      category: "Alquiler",
      amount: 150000,
      paymentMethodName: "Transferencia bancaria",
    })
    expect(dryRunCall.rows[1].paymentMethodName).toBeNull()
  })
})

describe("ExpenseImportDialog — el payload NUNCA lleva sesión de caja (D6, aserción PERMANENTE)", () => {
  it("ni la simulación ni la confirmación incluyen ninguna clave de sesión de caja", async () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    await uploadCsv()

    for (const [input] of importMock.mock.calls) {
      expect("cashSessionId" in input).toBe(false)
      expect("cash_session_id" in input).toBe(false)
      for (const row of input.rows ?? []) {
        expect("cashSessionId" in row).toBe(false)
        expect("cash_session_id" in row).toBe(false)
      }
    }
  })
})
