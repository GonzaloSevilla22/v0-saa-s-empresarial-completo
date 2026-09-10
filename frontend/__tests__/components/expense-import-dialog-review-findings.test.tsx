/**
 * Importador de gastos — hallazgos de la revisión adversarial post-apply
 * (importador-gastos-transaccional, F1 y F2 del informe de revisión).
 *
 * F1: elegir un archivo nuevo (o que la simulación del archivo elegido
 * falle) tiene que limpiar `serverVerdicts`/`serverResult` — si no, el
 * veredicto del archivo ANTERIOR (indexado por número de fila) se pinta
 * sobre las filas del archivo NUEVO, porque `serverVerdicts[row.rowNum]`
 * no distingue de qué archivo vino ese número de fila.
 *
 * F2: el tope de 500 filas (D8 del design, mismo que aplica
 * `rpc_import_expenses` vía P0427) tiene que cortarse en el CLIENTE antes
 * de avanzar al paso 2 — si no, el usuario paga el viaje entero a la RPC
 * sólo para recibir un 422 que ni siquiera ve (ver F2 del informe: con la
 * simulación fallada, `serverVerdicts` queda vacío y `confirmDisabled` da
 * `false`, así que el botón de confirmar queda HABILITADO).
 *
 * Mismo molde de mocks que `expense-import-dialog-invalidation.test.tsx`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent } from "@testing-library/react"
import { toast } from "sonner"

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

function changeFile(csv: string, name: string) {
  const input = document.getElementById("csv-expense-upload") as HTMLInputElement
  fireEvent.change(input, { target: { files: [new File([csv], name, { type: "text/csv" })] } })
}

const csvA = [
  "Descripción;Categoría;Monto;Fecha",
  "Gasto A1;Servicios;1000;2026-08-01",
  "Gasto A2;Servicios;2000;2026-08-02",
].join("\n")

const csvB = [
  "Descripción;Categoría;Monto;Fecha",
  "Gasto B1;Servicios;500;2026-08-03",
  "Gasto B2;Servicios;700;2026-08-04",
].join("\n")

function dryRunWithStaleError() {
  return {
    committed: false, importId: null, imported: 1,
    // rowNum 3 = la 2ª fila de datos (header = fila 1). csvB también tiene
    // una fila con rowNum 3 ("Gasto B2") — el mismo número de fila que un
    // archivo DISTINTO, a propósito: es justo el escenario que rompe si el
    // veredicto no se limpia (el lookup es por rowNum, no por archivo).
    errors: [{ row: 3, code: "P0400", message: "ERROR_STALE_FILE_A" }],
    notices: [], replayed: false, dryRun: true,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("ExpenseImportDialog — F1: el veredicto del servidor no sobrevive a un cambio de archivo", () => {
  it("elegir un archivo nuevo limpia el veredicto del archivo anterior antes de que la nueva simulación resuelva", async () => {
    importMock.mockResolvedValueOnce(dryRunWithStaleError())
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    changeFile(csvA, "gastos-a.csv")

    await waitFor(() => expect(screen.getByText("ERROR_STALE_FILE_A")).toBeInTheDocument())

    fireEvent.click(screen.getByRole("button", { name: /cambiar archivo/i }))

    // La simulación del archivo B queda pendiente A PROPÓSITO — la
    // aserción de abajo corre ANTES de que resuelva, para probar que la
    // limpieza pasa en `handleFile` (al elegir el archivo), no como efecto
    // secundario de que la simulación nueva termine.
    let resolveB!: (v: unknown) => void
    importMock.mockImplementationOnce(() => new Promise((resolve) => { resolveB = resolve }))
    changeFile(csvB, "gastos-b.csv")

    await waitFor(() => expect(screen.getByText("Gasto B1")).toBeInTheDocument())
    expect(screen.queryByText("ERROR_STALE_FILE_A")).not.toBeInTheDocument()

    // Asentar la promesa pendiente para no dejar un `act()` colgado.
    resolveB({ committed: false, importId: null, imported: 2, errors: [], notices: [], replayed: false, dryRun: true })
    await waitFor(() => expect(importMock).toHaveBeenCalledTimes(2))
  })

  it("un fallo de red en la simulación no deja veredictos huérfanos del archivo anterior", async () => {
    importMock.mockResolvedValueOnce(dryRunWithStaleError())
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    changeFile(csvA, "gastos-a.csv")
    await waitFor(() => expect(screen.getByText("ERROR_STALE_FILE_A")).toBeInTheDocument())

    fireEvent.click(screen.getByRole("button", { name: /cambiar archivo/i }))
    importMock.mockRejectedValueOnce(new Error("network down"))
    changeFile(csvB, "gastos-b.csv")

    await waitFor(() => expect(toast.error).toHaveBeenCalled())
    // Sin el fix, `serverVerdicts` de A (rowNum 3) sigue vivo para siempre
    // (no hay reintento automático) y se pinta sobre la fila B2 (rowNum 3).
    expect(screen.queryByText("ERROR_STALE_FILE_A")).not.toBeInTheDocument()
  })
})

describe("ExpenseImportDialog — F2: el tope de 500 filas se aplica en el cliente", () => {
  function csvWithRows(rowCount: number): string {
    const header = "Descripción;Categoría;Monto;Fecha"
    const rows = Array.from({ length: rowCount }, (_, i) => `Gasto ${i + 1};Servicios;1000;2026-08-01`)
    return [header, ...rows].join("\n")
  }

  it("un CSV de 501 filas se corta con toast.error, sin avanzar al paso 2 ni llamar al servidor", async () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    changeFile(csvWithRows(501), "gastos-501.csv")

    await waitFor(() => expect(toast.error).toHaveBeenCalledWith(expect.stringContaining("500")))
    // Sigue en el paso 1: la drop zone de subida sigue en pantalla.
    expect(screen.getByLabelText(/hacé clic o arrastrá tu archivo csv/i)).toBeInTheDocument()
    expect(screen.queryByText(/501 filas/i)).not.toBeInTheDocument()
    expect(importMock).not.toHaveBeenCalled()
  })

  it("un CSV de exactamente 500 filas (el tope, no lo excede) sí avanza al paso 2", async () => {
    importMock.mockResolvedValueOnce({
      committed: false, importId: null, imported: 500, errors: [], notices: [], replayed: false, dryRun: true,
    })
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    changeFile(csvWithRows(500), "gastos-500.csv")

    // "Importar 500 gastos" sólo existe en el footer del paso 2, con el
    // conteo real de filas OK — a diferencia del conteo de filas de arriba
    // (un <span> anidado), acá el número y la palabra comparten UN nodo de
    // texto, así que no hay ambigüedad con los números de fila (1..500)
    // que también aparecen sueltos en la columna "#".
    await waitFor(() => expect(screen.getByRole("button", { name: /importar 500 gastos/i })).toBeInTheDocument())
    expect(toast.error).not.toHaveBeenCalled()
  })
})
