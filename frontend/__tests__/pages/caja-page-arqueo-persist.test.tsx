/**
 * qa-integral-modulos G6 (H6) — el arqueo del cierre de caja se autodestruía:
 * el <CloseSessionDialog> vivía ADENTRO del ternario {!currentSession ? … : …}
 * de caja/page.tsx, así que cuando el refetch de current-session resolvía a
 * "sin sesión" (404 → null) la rama se invertía y Radix desmontaba el diálogo
 * con el panel de resultado adentro (ventana de visibilidad medida: 56–181 ms).
 * Fix (task 6.2): el diálogo sube fuera del ternario con estado `open` propio
 * a nivel página — mismo patrón que LedgerAdjustmentDialog.
 *
 * El mock de useCloseSession replica la carrera REAL en su forma más cruel:
 * al resolver la mutación, current-session ya es null (red rápida) — el panel
 * debe seguir montado igual.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, waitFor } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import React from "react"

const mockUseSearchParams = vi.fn()
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
}))

const OPEN_SESSION = {
  id: "sess-1234-5678",
  cashboxId: "cashbox-1",
  status: "open" as const,
  openingBalance: 38200,
  closingBalance: null,
  countedBalance: null,
  expectedBalance: null,
  difference: null,
  openedBy: "user-1",
  closedBy: null,
  openedAt: "2026-08-31T10:00:00Z",
  closedAt: null,
  adjustmentsTotal: 0,
}

// Fixture MUTABLE: la mutación de cierre lo pone en null, simulando el
// refetch de current-session que resuelve a "sin sesión" (la carrera de H6).
let currentSessionFixture: typeof OPEN_SESSION | null = OPEN_SESSION
const closeMutateAsync = vi.fn()

vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({
    branches: [{ id: "branch-1", name: "Casa Central" }],
    isLoading: false,
  }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: () => ({ data: [{ id: "cashbox-1", name: "Caja 1" }], isLoading: false }),
  useCreateCashbox: () => ({ mutateAsync: vi.fn(), isPending: false, isError: false }),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: currentSessionFixture, isLoading: false }),
  useCashSessions: () => ({ data: [], isLoading: false }),
  useOpenSession: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCloseSession: () => ({ mutateAsync: closeMutateAsync, isPending: false }),
}))
vi.mock("@/hooks/data/use-cash-movements", () => ({
  useCashMovements: () => ({ data: [] }),
  useRegisterMovement: () => ({ mutateAsync: vi.fn(), isPending: false }),
  fetchCashMovementsByCashboxPage: vi
    .fn()
    .mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 }),
}))
vi.mock("@/components/ledger/LedgerMovementsPanel", () => ({
  LedgerMovementsPanel: () => <div data-testid="ledger-panel" />,
}))
vi.mock("@/components/ledger/LedgerAdjustmentDialog", () => ({
  LedgerAdjustmentDialog: () => <div data-testid="adjustment-dialog" />,
}))

async function renderCajaPage() {
  const { default: CajaPage } = await import("@/app/(dashboard)/caja/page")
  return render(<CajaPage />)
}

/** Abre el diálogo, tipea el contado y confirma el cierre. */
async function closeWithCounted(counted: string) {
  const user = userEvent.setup()
  await user.click(screen.getByRole("button", { name: "Cerrar caja" }))
  await user.type(await screen.findByLabelText("Efectivo contado ($)"), counted)
  await user.click(screen.getByRole("button", { name: "Confirmar cierre" }))
  return user
}

beforeEach(() => {
  mockUseSearchParams.mockReturnValue(new URLSearchParams())
  currentSessionFixture = OPEN_SESSION
  closeMutateAsync.mockReset()
  closeMutateAsync.mockImplementation(async () => {
    // Red rápida: cuando la mutación resuelve, el refetch YA volvió con 404.
    currentSessionFixture = null
    return { session_id: OPEN_SESSION.id, status: "closed" }
  })
})

describe("/caja — el panel de arqueo sobrevive al refetch de current-session (G6/H6)", () => {
  it("cierre con faltante: el panel de resultado sigue montado cuando la sesión ya es null", async () => {
    await renderCajaPage()
    await closeWithCounted("1000")

    // El cierre ocurrió y la pantalla ya está en "sin sesión"…
    await waitFor(() => expect(closeMutateAsync).toHaveBeenCalledTimes(1))
    expect(await screen.findByText("No hay ninguna sesión de caja abierta.")).toBeInTheDocument()

    // …pero el arqueo NO se autodestruyó: faltante de $37.200 visible.
    expect(screen.getByText(/Faltante en caja/)).toBeInTheDocument()
    expect(screen.getByText(/37\.200,00/)).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Listo" })).toBeInTheDocument()
  })

  it("arqueo exacto: el panel 'sin diferencia' también persiste", async () => {
    await renderCajaPage()
    await closeWithCounted("38200")

    await waitFor(() => expect(closeMutateAsync).toHaveBeenCalledTimes(1))
    expect(await screen.findByText("No hay ninguna sesión de caja abierta.")).toBeInTheDocument()
    expect(screen.getByText(/Arqueo exacto — sin diferencia/)).toBeInTheDocument()
  })

  it("sobrante: el panel muestra el sobrante y persiste", async () => {
    await renderCajaPage()
    await closeWithCounted("40000")

    await waitFor(() => expect(closeMutateAsync).toHaveBeenCalledTimes(1))
    expect(await screen.findByText("No hay ninguna sesión de caja abierta.")).toBeInTheDocument()
    expect(screen.getByText(/Sobrante en caja/)).toBeInTheDocument()
    expect(screen.getByText(/\+\$/)).toBeInTheDocument()
  })

  it("'Listo' cierra el panel y la pantalla queda en 'sin sesión abierta'", async () => {
    await renderCajaPage()
    const user = await closeWithCounted("1000")

    await screen.findByText(/Faltante en caja/)
    await user.click(screen.getByRole("button", { name: "Listo" }))

    await waitFor(() =>
      expect(screen.queryByText(/Faltante en caja/)).not.toBeInTheDocument(),
    )
    expect(screen.getByText("No hay ninguna sesión de caja abierta.")).toBeInTheDocument()
    // La pantalla queda operable para abrir una sesión nueva.
    expect(screen.getByText("Abrir sesión de caja")).toBeInTheDocument()
    expect(screen.getByLabelText("Saldo inicial ($)")).toBeInTheDocument()
  })
})
