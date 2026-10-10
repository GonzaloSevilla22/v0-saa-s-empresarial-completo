/**
 * ventas-sucursal-por-defecto (D10, tarea 5.2) — `useCashOptin` resuelve la
 * sucursal efectiva con `resolveDefaultBranch` (espejo de `c26_default_branch`)
 * y no con `branches[0]`.
 *
 * Con la sucursal más antigua CERRADA, `branches[0]` la tomaba como principal
 * mientras el servidor (que exige `status = 'active'`) usa la siguiente: el
 * opt-in de caja buscaba la sesión en una sucursal que el servidor no iba a
 * usar. Alcanza a sus cinco consumidores (venta, compra, gasto, cobro y pago de
 * cuenta corriente).
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { renderHook } from "@testing-library/react"
import { useCashOptin } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"
import type { Branch } from "@/lib/types"

function branch(id: string, overrides: Partial<Branch> = {}): Branch {
  return {
    id,
    accountId: "acc-1",
    name: `Sucursal ${id}`,
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

const useBranchesMock = vi.fn()
const useCashboxesMock = vi.fn()
const useCurrentSessionMock = vi.fn()

vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => useBranchesMock() }))
vi.mock("@/hooks/data/use-cashboxes", () => ({ useCashboxes: (...args: unknown[]) => useCashboxesMock(...args) }))
vi.mock("@/hooks/data/use-cash-session", () => ({ useCurrentSession: (...args: unknown[]) => useCurrentSessionMock(...args) }))

afterEach(() => {
  vi.clearAllMocks()
})

describe("useCashOptin — la sucursal efectiva es la principal del servidor", () => {
  it("la más antigua CERRADA: la sucursal efectiva es la siguiente operativa y la caja se busca ahí", () => {
    useBranchesMock.mockReturnValue({
      branches: [branch("b-cerrada", { status: "closed" }), branch("b-segunda"), branch("b-tercera")],
    })
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-2" }] })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-2" } })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: null, date: argentinaToday() })
    )

    expect(result.current.effectiveBranchId).toBe("b-segunda")
    expect(useCashboxesMock).toHaveBeenCalledWith("b-segunda")
    expect(result.current.eligible).toBe(true)
  })

  it("sin ninguna cerrada: sigue siendo la primera (sin cambio de comportamiento)", () => {
    useBranchesMock.mockReturnValue({ branches: [branch("b-primera"), branch("b-segunda")] })
    useCashboxesMock.mockReturnValue({ data: [] })
    useCurrentSessionMock.mockReturnValue({ data: null })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: null, date: argentinaToday() })
    )

    expect(result.current.effectiveBranchId).toBe("b-primera")
  })

  it("una sucursal ELEGIDA gana sobre la principal, aunque esté cerrada la más antigua", () => {
    useBranchesMock.mockReturnValue({ branches: [branch("b-cerrada", { status: "closed" }), branch("b-segunda")] })
    useCashboxesMock.mockReturnValue({ data: [] })
    useCurrentSessionMock.mockReturnValue({ data: null })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "b-elegida", date: argentinaToday() })
    )

    expect(result.current.effectiveBranchId).toBe("b-elegida")
  })

  it("cuenta sin sucursales: no hay sucursal efectiva", () => {
    useBranchesMock.mockReturnValue({ branches: [] })
    useCashboxesMock.mockReturnValue({ data: undefined })
    useCurrentSessionMock.mockReturnValue({ data: undefined })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: null, date: argentinaToday() })
    )

    expect(result.current.effectiveBranchId).toBeNull()
  })
})
