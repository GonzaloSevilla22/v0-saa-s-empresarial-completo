/**
 * qa-integral-modulos G10 (H21b) — "Conciliar selección" quedaba HABILITADO
 * aunque la propia pantalla ya avisaba "Las sumas no coinciden" al lado: el
 * `disabled` solo miraba la cantidad de ítems, así que el clic terminaba en
 * el 422 crudo del servidor (`amounts_mismatch`). Con las sumas distintas el
 * botón se deshabilita; con sumas iguales sigue operable.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import "@testing-library/jest-dom"

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
      amount: 420000,
      balance: null,
      matched: false,
    },
    {
      id: "l2",
      lineNo: 2,
      valueDate: "2026-08-11",
      description: "Débito servicio",
      amount: -64000,
      balance: null,
      matched: false,
    },
  ],
  pendingMovements: [
    {
      id: "m1",
      amount: -64000,
      movementType: "transfer_out",
      valueDate: "2026-08-11",
      description: "Pago proveedor",
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

function matchButton() {
  return screen.getByRole("button", { name: /Conciliar selección/ })
}

describe("ReconciliationBoard — el botón respeta el aviso de sumas (G10/H21b)", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("sumas distintas: el aviso aparece y el botón queda deshabilitado", async () => {
    const user = userEvent.setup()
    render(<ReconciliationBoard sessionId="s1" bankAccountId="b1" />)

    // Línea de $420.000 vs movimiento de -$64.000 (los montos del QA)
    await user.click(screen.getByText(/Transferencia recibida/))
    await user.click(screen.getByText(/Pago proveedor/))

    expect(screen.getByText(/Las sumas no coinciden/)).toBeInTheDocument()
    expect(matchButton()).toBeDisabled()
  })

  it("sumas iguales: sin aviso y el botón sigue operable", async () => {
    const user = userEvent.setup()
    render(<ReconciliationBoard sessionId="s1" bankAccountId="b1" />)

    await user.click(screen.getByText(/Débito servicio/))
    await user.click(screen.getByText(/Pago proveedor/))

    expect(screen.queryByText(/Las sumas no coinciden/)).not.toBeInTheDocument()
    expect(matchButton()).toBeEnabled()
  })

  it("sin selección de un lado: sigue deshabilitado por cantidad (comportamiento previo intacto)", async () => {
    const user = userEvent.setup()
    render(<ReconciliationBoard sessionId="s1" bankAccountId="b1" />)

    await user.click(screen.getByText(/Transferencia recibida/))
    expect(matchButton()).toBeDisabled()
  })
})
