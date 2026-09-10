/**
 * Importador de gastos — invalidaciones (importador-gastos-transaccional,
 * D13/task 8.9: adapta el intento del test viejo al hook nuevo).
 *
 * La INTENCIÓN del test original sigue valiendo tal cual: una sola
 * invalidación por LOTE, no una por fila. Lo que cambia es que ahora hay
 * UNA sola llamada HTTP (`POST /expenses/import`) en vez de N llamadas a
 * `POST /expenses` — así que "una invalidación por lote" ya no hace falta
 * demostrarlo comparando 3 filas contra 6: alcanza con verificar que
 * `invalidateLedgers()` se llama EXACTAMENTE una vez tras un lote
 * confirmado, sea cual sea su tamaño, y CERO veces mientras el diálogo sólo
 * está en la simulación (paso 2) o si el lote fue rechazado.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, cleanup, screen, waitFor, fireEvent } from "@testing-library/react"

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
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/components/branches/BranchSelect", () => ({ BranchSelect: () => null }))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))

import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"

function csvWith(rowCount: number): string {
  const header = "Descripción;Categoría;Monto;Fecha"
  const rows = Array.from({ length: rowCount }, (_, i) =>
    `Gasto ${i + 1};Servicios;${(i + 1) * 1000};2026-08-0${(i % 9) + 1}`,
  )
  return [header, ...rows].join("\n")
}

function dryRunResult(rowCount: number) {
  return { committed: false, importId: null, imported: rowCount, errors: [], notices: [], replayed: false, dryRun: true }
}
function appliedResult(rowCount: number) {
  return { committed: true, importId: "import-1", imported: rowCount, errors: [], notices: [], replayed: false, dryRun: false }
}
function rejectedResult() {
  return { committed: false, importId: null, imported: 0, errors: [{ row: 1, code: "P0400", message: "boom" }], notices: [], replayed: false, dryRun: false }
}

async function importCsv(rowCount: number) {
  // El primer test de este archivo llama a `importCsv` DOS VECES en el mismo
  // `it` (3 filas y luego 6) para comparar invalidaciones — sin desmontar el
  // primer diálogo entre medio, ambos árboles de React (y sus efectos de
  // dry-run automático, D9) quedan montados a la vez, lo que se volvió
  // observable como flake bajo carga (hallazgo real de esta sesión). `cleanup()`
  // es un no-op si no hay nada montado, así que es seguro en la primera llamada.
  cleanup()
  render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

  const input = document.getElementById("csv-expense-upload") as HTMLInputElement
  fireEvent.change(input, { target: { files: [new File([csvWith(rowCount)], "gastos.csv", { type: "text/csv" })] } })

  const label = new RegExp(`importar ${rowCount} gastos?`, "i")
  // El botón aparece con su texto final ANTES de que la simulación (D9)
  // resuelva — sólo queda DESHABILITADO mientras `serverLoading` es true
  // (confirmDisabled). Esperar sólo `toBeInTheDocument()` es una carrera real:
  // un click sobre el botón todavía deshabilitado no dispara el handler y la
  // confirmación nunca ocurre (hallazgo real de esta sesión, ~1 de cada 4
  // corridas). Hay que esperar a que la simulación termine y lo habilite.
  await waitFor(() => expect(screen.getByRole("button", { name: label })).not.toBeDisabled())
  fireEvent.click(screen.getByRole("button", { name: label }))
  await waitFor(() => expect(importMock).toHaveBeenCalledTimes(2)) // dry-run + confirmación
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("ExpenseImportDialog — la importación invalida UNA sola vez por lote confirmado", () => {
  it("un lote de 3 filas invalida el mismo número de veces (1) que uno de 6", async () => {
    importMock.mockResolvedValueOnce(dryRunResult(3)).mockResolvedValueOnce(appliedResult(3))
    await importCsv(3)
    expect(invalidateLedgersMock).toHaveBeenCalledTimes(1)

    vi.clearAllMocks()
    importMock.mockResolvedValueOnce(dryRunResult(6)).mockResolvedValueOnce(appliedResult(6))
    await importCsv(6)
    expect(invalidateLedgersMock).toHaveBeenCalledTimes(1)
  })

  it("la simulación (paso 2) NO invalida nada — sólo la confirmación real", async () => {
    importMock.mockResolvedValueOnce(dryRunResult(2))
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    const input = document.getElementById("csv-expense-upload") as HTMLInputElement
    fireEvent.change(input, { target: { files: [new File([csvWith(2)], "gastos.csv", { type: "text/csv" })] } })

    await waitFor(() => expect(importMock).toHaveBeenCalledTimes(1))
    expect(invalidateLedgersMock).not.toHaveBeenCalled()
  })

  it("un lote RECHAZADO no invalida nada — nada se escribió", async () => {
    importMock.mockResolvedValueOnce(dryRunResult(2)).mockResolvedValueOnce(rejectedResult())

    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    const input = document.getElementById("csv-expense-upload") as HTMLInputElement
    fireEvent.change(input, { target: { files: [new File([csvWith(2)], "gastos.csv", { type: "text/csv" })] } })

    // Mismo motivo que en `importCsv`: esperar a que esté HABILITADO, no sólo
    // presente — si no, el click puede caer sobre el botón aún deshabilitado
    // por `serverLoading` y la confirmación nunca se dispara.
    await waitFor(() => expect(screen.getByRole("button", { name: /importar 2 gastos/i })).not.toBeDisabled())
    fireEvent.click(screen.getByRole("button", { name: /importar 2 gastos/i }))

    await waitFor(() => expect(importMock).toHaveBeenCalledTimes(2))
    expect(invalidateLedgersMock).not.toHaveBeenCalled()
  })

  it("no dispara un GET del listado por fila — sólo las dos llamadas de la mutación (dry-run + confirmar)", async () => {
    importMock.mockResolvedValueOnce(dryRunResult(6)).mockResolvedValueOnce(appliedResult(6))
    await importCsv(6)
    expect(importMock).toHaveBeenCalledTimes(2)
  })
})
