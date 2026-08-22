/**
 * banco-caja-historial-ajustes (D8) — /caja resuelve sucursal y caja
 * ADENTRO de la pantalla: preselecciona la sucursal si hay una sola y la
 * caja si la sucursal tiene una sola (37 cajas / 40 sucursales ≈ 1:1 en
 * prod) — sin selector visible en ese caso. El selector aparece solo
 * cuando hay más de una opción.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import React from "react"

const mockUseSearchParams = vi.fn()
vi.mock("next/navigation", () => ({
  useSearchParams: () => mockUseSearchParams(),
}))

let branchesFixture: { id: string; name: string }[] = []
let cashboxesFixture: { id: string; name: string }[] = []

vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: branchesFixture, isLoading: false }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: () => ({ data: cashboxesFixture, isLoading: false }),
  useCreateCashbox: () => ({ mutateAsync: vi.fn(), isPending: false, isError: false }),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: () => ({ data: null, isLoading: false }),
  useCashSessions: () => ({ data: [], isLoading: false }),
  useOpenSession: () => ({ mutateAsync: vi.fn(), isPending: false }),
  useCloseSession: () => ({ mutateAsync: vi.fn(), isPending: false }),
}))
vi.mock("@/hooks/data/use-cash-movements", () => ({
  useCashMovements: () => ({ data: [] }),
  useRegisterMovement: () => ({ mutateAsync: vi.fn(), isPending: false }),
  fetchCashMovementsByCashboxPage: vi.fn().mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 }),
}))
vi.mock("@/components/ledger/LedgerMovementsPanel", () => ({
  LedgerMovementsPanel: ({ scopeKey }: { scopeKey: string }) => (
    <div data-testid="ledger-panel">scope:{scopeKey}</div>
  ),
}))
vi.mock("@/components/ledger/LedgerAdjustmentDialog", () => ({
  LedgerAdjustmentDialog: () => <div data-testid="adjustment-dialog" />,
}))

async function renderCajaPage() {
  const { default: CajaPage } = await import("@/app/(dashboard)/caja/page")
  return render(<CajaPage />)
}

beforeEach(() => {
  mockUseSearchParams.mockReturnValue(new URLSearchParams())
})

describe("/caja — preselección de sucursal y caja", () => {
  it("una sola sucursal y una sola caja: sin selectores, la caja se resuelve sola", async () => {
    branchesFixture = [{ id: "branch-1", name: "Casa Central" }]
    cashboxesFixture = [{ id: "cashbox-1", name: "Caja 1" }]

    await renderCajaPage()

    // Sin combos visibles — la única opción se preselecciona (D8)
    expect(screen.queryByText("Elegí la sucursal")).not.toBeInTheDocument()
    expect(screen.queryByText("Elegí la caja")).not.toBeInTheDocument()
    expect(await screen.findByTestId("ledger-panel")).toHaveTextContent("scope:cashbox-1")
  })

  it("varias sucursales: se muestra el selector de sucursal", async () => {
    branchesFixture = [
      { id: "branch-1", name: "Casa Central" },
      { id: "branch-2", name: "Sucursal Norte" },
    ]
    cashboxesFixture = []

    await renderCajaPage()

    expect(screen.getByText("Elegí la sucursal")).toBeInTheDocument()
  })

  it("una sucursal con varias cajas: se muestra el selector de caja (con la primera preseleccionada)", async () => {
    branchesFixture = [{ id: "branch-1", name: "Casa Central" }]
    cashboxesFixture = [
      { id: "cashbox-1", name: "Caja 1" },
      { id: "cashbox-2", name: "Caja 2" },
    ]

    await renderCajaPage()

    expect(screen.queryByText("Elegí la sucursal")).not.toBeInTheDocument()
    // El selector de caja existe (>1 opción) — preseleccionado en la primera,
    // con la segunda disponible como opción (Radix Select).
    expect(screen.getAllByText("Caja 1").length).toBeGreaterThan(0)
    expect(await screen.findByTestId("ledger-panel")).toHaveTextContent("scope:cashbox-1")
  })

  it("respeta ?branch= de la URL (viene del redirect de /sucursales/[id]/caja)", async () => {
    mockUseSearchParams.mockReturnValue(new URLSearchParams("branch=branch-from-url"))
    branchesFixture = [
      { id: "branch-1", name: "Casa Central" },
      { id: "branch-from-url", name: "Sucursal del redirect" },
    ]
    cashboxesFixture = [{ id: "cashbox-9", name: "Caja 1" }]

    await renderCajaPage()

    expect(await screen.findByTestId("ledger-panel")).toHaveTextContent("scope:cashbox-9")
  })
})
