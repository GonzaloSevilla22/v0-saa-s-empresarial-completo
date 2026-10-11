/**
 * Importador de gastos — la sucursal por defecto a la vista
 * (compras-gastos-sucursal-por-defecto, D9, tarea 5.3).
 *
 * El importador pasa la «Sucursal por defecto» del lote a `rpc_import_expenses`, que la entrega
 * a `rpc_create_expense` fila por fila; con `NULL` el alta resuelve la sucursal PRINCIPAL
 * (`gastos-forma-pago` D6). El selector decía «Sin sucursal por defecto» aunque se guardara la
 * principal: el rótulo mentía. Desde este change deja de ofrecer esa opción y muestra la
 * principal ya elegida, rotulada «(principal)», con el rótulo «Sucursal por defecto» a juego con
 * «Forma de pago por defecto» y «Centro de costo por defecto».
 *
 * El estado sigue en `null` hasta que el usuario elige otra: el lote viaja con
 * `defaultBranchId: null` y cada fila sin sucursal propia cae en la principal por el alta del
 * gasto — lo mostrado es lo que se guarda.
 *
 * Se monta el `BranchSelect` REAL con el Select de Radix real (mock de los hooks de plan y de
 * sucursales); los otros dos selectores por defecto se mockean a null como en los demás tests del
 * diálogo.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor, fireEvent, within } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import type { Branch } from "@/lib/types"

const importMock = vi.fn()
const invalidateLedgersMock = vi.fn()
const usePlanLimitsMock = vi.fn()
const useBranchesMock = vi.fn()

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
vi.mock("@/hooks/auth/use-plan-limits", () => ({ usePlanLimits: () => usePlanLimitsMock() }))
vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => useBranchesMock() }))
vi.mock("@/components/payment-methods/PaymentMethodSelect", () => ({
  PaymentMethodSelect: () => null,
  BankAccountDestinationSelect: () => null,
}))
vi.mock("@/components/cost-centers/CostCenterSelect", () => ({ CostCenterSelect: () => null }))

import { ExpenseImportDialog } from "@/components/gastos/expense-import-dialog"

function branch(overrides: Partial<Branch> & { id: string; name: string }): Branch {
  return {
    accountId: "acc-1",
    address: null,
    isActive: true,
    createdAt: "2026-01-01T00:00:00Z",
    status: "active",
    openedAt: null,
    closedAt: null,
    createdBy: null,
    deactivatedAt: null,
    deactivatedBy: null,
    ...overrides,
  }
}

const CENTRO = branch({ id: "b-centro", name: "Centro" })
const SHOWROOM = branch({ id: "b-show", name: "Showroom", createdAt: "2026-03-01T00:00:00Z" })

const CSV = [
  "Descripción;Categoría;Monto;Fecha;Forma de pago;Sucursal;Centro de costo",
  "Alquiler del local;Alquiler;150000;2026-08-01;;;",
  "Factura de luz;Servicios;12000;2026-08-05;;;",
].join("\n")

beforeEach(() => {
  vi.clearAllMocks()
  usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: true } })
  useBranchesMock.mockReturnValue({ branches: [CENTRO, SHOWROOM], isLoading: false, isError: false })
  importMock.mockResolvedValue({
    committed: false, importId: null, imported: 2, errors: [], notices: [], replayed: false, dryRun: true,
  })
})

async function uploadCsv() {
  const input = document.getElementById("csv-expense-upload") as HTMLInputElement
  fireEvent.change(input, { target: { files: [new File([CSV], "gastos.csv", { type: "text/csv" })] } })
  // El paso 2 dispara la SIMULACIÓN automáticamente al entrar.
  await waitFor(() => expect(importMock).toHaveBeenCalled())
}

describe("ExpenseImportDialog — el selector de sucursal por defecto muestra la principal", () => {
  it("muestra la principal rotulada «(principal)», sin «Sin sucursal por defecto», con su rótulo «Sucursal por defecto»", async () => {
    const user = userEvent.setup()
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    const trigger = screen.getByRole("combobox", { name: "Sucursal por defecto" })
    expect(trigger).toHaveTextContent("Centro (principal)")
    expect(trigger).not.toHaveTextContent(/sin sucursal/i)

    await user.click(trigger)
    const options = within(await screen.findByRole("listbox")).getAllByRole("option").map((o) => o.textContent)
    expect(options).toEqual(["Centro (principal)", "Showroom"])
  })

  it("getByLabelText('Sucursal por defecto') encuentra el disparador (rótulo asociado por id)", () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    expect(screen.getByLabelText("Sucursal por defecto")).toBe(
      screen.getByRole("combobox", { name: "Sucursal por defecto" }),
    )
  })

  it("sin tocar el selector, el lote viaja con defaultBranchId null: cada fila sin sucursal propia cae en la principal", async () => {
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)
    await uploadCsv()

    const dryRun = importMock.mock.calls[0][0]
    expect(dryRun.dryRun).toBe(true)
    expect(dryRun.defaultBranchId).toBeNull()
  })

  it("elegir otra sucursal por defecto manda su id", async () => {
    const user = userEvent.setup()
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    await user.click(screen.getByRole("combobox", { name: "Sucursal por defecto" }))
    await user.click(await screen.findByRole("option", { name: "Showroom" }))
    await uploadCsv()

    expect(importMock.mock.calls[0][0].defaultBranchId).toBe("b-show")
  })

  it("cuenta sin el módulo de sucursales: ni selector ni rótulo", () => {
    usePlanLimitsMock.mockReturnValue({ limits: { hasBranchesModule: false } })
    render(<ExpenseImportDialog open onOpenChange={vi.fn()} />)

    expect(screen.queryByRole("combobox", { name: "Sucursal por defecto" })).not.toBeInTheDocument()
    expect(screen.queryByLabelText("Sucursal por defecto")).not.toBeInTheDocument()
    expect(document.body.textContent ?? "").not.toMatch(/sin sucursal por defecto/i)
  })
})
