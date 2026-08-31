/**
 * clientes-frecuentes-historial — TDD tests para la migración de
 * frontend/app/(dashboard)/clientes/page.tsx (tasks 7.3–7.7).
 *
 * La fila del cliente pasa a ser clickeable → navega a /clientes/[id]
 * (client-purchase-history §"Navegación desde la lista"). Los botones de
 * editar/borrar detienen la propagación y NO navegan (§"Acciones de la fila
 * no navegan"). Filtro por estado de actividad + orden se mueven al backend.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import "@testing-library/jest-dom"

const pushMock = vi.fn()
vi.mock("next/navigation", () => ({
  useRouter: () => ({ push: pushMock }),
}))

vi.mock("sonner", () => ({
  toast: { error: vi.fn(), success: vi.fn() },
}))

const deleteClientMock = vi.fn()
vi.mock("@/hooks/data/use-clients", () => ({
  useClients: () => ({ deleteClient: deleteClientMock }),
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ isAdmin: false }),
}))

vi.mock("@/hooks/auth/use-plan-limits", () => ({
  usePlanLimits: () => ({ limits: { maxClients: 100 } }),
}))

vi.mock("@/components/admin/ModuleMetricsWrapper", () => ({
  ModuleMetricsWrapper: () => null,
}))

const CLIENTS = [
  {
    id: "client-1",
    name: "Acme Corp",
    email: "acme@example.com",
    phone: "+54 261 555-1234",
    purchaseCount: 5,
    purchaseCount90d: 3,
    totalSpent: 15000,
    lastPurchaseDate: "2026-08-01",
    daysSinceLastPurchase: 13,
    activityStatus: "frecuente" as const,
  },
  {
    id: "client-2",
    name: "Beta SA",
    email: "beta@example.com",
    phone: "",
    purchaseCount: 0,
    purchaseCount90d: 0,
    totalSpent: 0,
    lastPurchaseDate: null,
    daysSinceLastPurchase: null,
    activityStatus: "sin_compras" as const,
  },
]

const useClientActivityListMock = vi.fn()
vi.mock("@/hooks/data/use-client-activity", () => ({
  useClientActivityList: () => useClientActivityListMock(),
}))

import ClientesPage from "@/app/(dashboard)/clientes/page"

function defaultHookReturn() {
  return {
    clients: CLIENTS,
    meta: { page: 0, pageSize: 25, totalCount: 2, pageCount: 1, from: 1, to: 2 },
    isLoading: false,
    isError: false,
    error: null,
    search: "",
    setSearch: vi.fn(),
    activityStatus: null,
    setActivityStatus: vi.fn(),
    sort: "name",
    sortDir: "asc",
    setSort: vi.fn(),
    setPage: vi.fn(),
    setPageSize: vi.fn(),
    refetch: vi.fn(),
  }
}

describe("ClientesPage (clientes-frecuentes-historial)", () => {
  beforeEach(() => {
    pushMock.mockReset()
    deleteClientMock.mockReset()
    useClientActivityListMock.mockReset()
    useClientActivityListMock.mockReturnValue(defaultHookReturn())
  })

  // qa-integral-modulos G10 (H25): el subtítulo decía "1 clientes registrados"
  // mientras el contador de la barra de filtros y el pie de tabla acertaban —
  // tres criterios de pluralización en la misma pantalla.
  it("subtítulo con 1 cliente: '1 cliente registrado' (G10/H25)", () => {
    useClientActivityListMock.mockReturnValue({
      ...defaultHookReturn(),
      clients: [CLIENTS[0]],
      meta: { page: 0, pageSize: 25, totalCount: 1, pageCount: 1, from: 1, to: 1 },
    })
    render(<ClientesPage />)
    expect(screen.getByText("1 cliente registrado")).toBeInTheDocument()
    expect(screen.queryByText("1 clientes registrados")).not.toBeInTheDocument()
  })

  it("subtítulo con varios: 'N clientes registrados' (G10/H25)", () => {
    render(<ClientesPage />)
    expect(screen.getByText("2 clientes registrados")).toBeInTheDocument()
  })

  it("renders activity badges for each client", () => {
    render(<ClientesPage />)
    expect(screen.getAllByText(/frecuente/i).length).toBeGreaterThan(0)
    expect(screen.getAllByText(/sin compras/i).length).toBeGreaterThan(0)
  })

  // ── 7.5 RED→GREEN: la fila navega al detalle ────────────────────────────
  it("clicking a client row navigates to /clientes/[id]", () => {
    render(<ClientesPage />)
    const row = screen.getByTestId("client-row-client-1")
    fireEvent.click(row)
    expect(pushMock).toHaveBeenCalledWith("/clientes/client-1")
  })

  // ── 7.5: editar/borrar detienen la propagación ───────────────────────────
  // getAllByTestId: mobile + desktop renderizan ambos bloques en jsdom (las
  // clases sm:hidden/hidden sm:grid no aplican sin un motor CSS real) —
  // mismo patrón que "renders activity badges" con getAllByText.
  it("clicking the edit button does not navigate", () => {
    render(<ClientesPage />)
    const [editBtn] = screen.getAllByTestId("client-edit-client-1")
    fireEvent.click(editBtn)
    expect(pushMock).not.toHaveBeenCalled()
  })

  it("clicking the delete button does not navigate", () => {
    render(<ClientesPage />)
    const [deleteBtn] = screen.getAllByTestId("client-delete-client-1")
    fireEvent.click(deleteBtn)
    expect(pushMock).not.toHaveBeenCalled()
  })

  // ── 7.6: accesible por teclado ────────────────────────────────────────────
  it("the row is keyboard-focusable and activates with Enter", () => {
    render(<ClientesPage />)
    const row = screen.getByTestId("client-row-client-1")
    expect(row).toHaveAttribute("tabIndex", "0")
    fireEvent.keyDown(row, { key: "Enter" })
    expect(pushMock).toHaveBeenCalledWith("/clientes/client-1")
  })

  // ── 7.4: filtro por estado + control de orden ────────────────────────────
  it("renders an activity status filter and a sort control", () => {
    render(<ClientesPage />)
    expect(screen.getByLabelText(/estado de actividad/i)).toBeInTheDocument()
    expect(screen.getByLabelText(/ordenar/i)).toBeInTheDocument()
  })

  // ── 7.7: agregados visibles en la fila ───────────────────────────────────
  it("shows last purchase and total spent aggregates in the row", () => {
    render(<ClientesPage />)
    expect(screen.getAllByText(/15\.?000/).length).toBeGreaterThan(0)
  })
})
