/**
 * qa-integral-modulos G13 / H18 (tablero de conciliación): el checkbox de cada
 * línea mide 16x16 px dentro de una fila de 78 px que NO era clickeable — en
 * móvil el tap solo acierta si cae exactamente en el centro del checkbox.
 *
 * Contrato (spec responsive-shell): la FILA ENTERA del extracto y del panel de
 * sistema alterna la selección; el checkbox y el botón "Anotar" siguen
 * funcionando sin doble-toggle.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"

const mutationMock = () => ({
  mutate: vi.fn(),
  mutateAsync: vi.fn().mockResolvedValue({}),
  isPending: false,
})

const pendingData = {
  session: {
    id: "s1",
    bankAccountId: "b1",
    status: "open" as const,
    periodFrom: "2026-08-01",
    periodTo: "2026-08-31",
    statementClosingBalance: 1000,
    ledgerClosingBalance: null,
    difference: null,
    closeReason: null,
    openedAt: "2026-08-01T00:00:00Z",
    closedAt: null,
  },
  pendingLines: [
    {
      id: "l1",
      lineNo: 1,
      valueDate: "2026-08-10",
      description: "Transferencia recibida",
      amount: 5000,
      balance: null,
      matched: false,
    },
  ],
  pendingMovements: [
    {
      id: "m1",
      amount: 5000,
      movementType: "transfer_in",
      valueDate: "2026-08-10",
      description: "Cobro cliente",
      balanceAfter: 5000,
      reconciliationStatus: "pending",
    },
  ],
}

vi.mock("@/hooks/data/use-bank-reconciliation", () => ({
  useSessionPending: () => ({ data: pendingData, isLoading: false }),
  useSessionMatches: () => ({ data: [] }),
  useSessionSuggestions: () => ({ data: [] }),
  useCreateMatch: () => mutationMock(),
  useUndoMatch: () => mutationMock(),
  useCloseSession: () => mutationMock(),
  useRegisterManualMovement: () => mutationMock(),
}))

import { ReconciliationBoard } from "@/components/bank-reconciliation/ReconciliationBoard"

function renderBoard() {
  return render(<ReconciliationBoard sessionId="s1" bankAccountId="b1" />)
}

describe("ReconciliationBoard — fila entera clickeable (H18)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("tocar la fila del extracto (fuera del checkbox) selecciona la línea", async () => {
    const user = userEvent.setup()
    renderBoard()

    const checkbox = screen.getAllByRole("checkbox")[0]
    expect(checkbox).not.toBeChecked()

    await user.click(screen.getByText(/Transferencia recibida/))
    expect(checkbox).toBeChecked()

    // Segundo tap sobre la fila: deselecciona
    await user.click(screen.getByText(/Transferencia recibida/))
    expect(checkbox).not.toBeChecked()
  })

  it("tocar la fila del panel de sistema selecciona el movimiento", async () => {
    const user = userEvent.setup()
    renderBoard()

    const checkbox = screen.getAllByRole("checkbox")[1]
    expect(checkbox).not.toBeChecked()

    await user.click(screen.getByText(/Cobro cliente/))
    expect(checkbox).toBeChecked()
  })

  it("el checkbox sigue alternando exactamente una vez por clic (sin doble-toggle)", async () => {
    const user = userEvent.setup()
    renderBoard()

    const checkbox = screen.getAllByRole("checkbox")[0]
    await user.click(checkbox)
    expect(checkbox).toBeChecked()
    await user.click(checkbox)
    expect(checkbox).not.toBeChecked()
  })

  it("el botón «Anotar» no altera la selección de la fila", async () => {
    const user = userEvent.setup()
    renderBoard()

    const checkbox = screen.getAllByRole("checkbox")[0]
    await user.click(screen.getByRole("button", { name: "Anotar" }))
    expect(checkbox).not.toBeChecked()
  })
})
