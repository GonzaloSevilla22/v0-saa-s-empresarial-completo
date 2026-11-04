/**
 * useCashOptin — estado de CARGA (fix `caja-optin-carga`, 2026-10-16).
 *
 * Caso real (humo de `remitos-compra` tanda B): el usuario confirma una
 * operación en efectivo ANTES de que carguen las cajas y la sesión. Mientras
 * `useCashboxes` / `useCurrentSession` cargan, `currentSession` es `undefined`
 * y `eligible` es `false` — indistinguible de «no hay caja abierta» — así que
 * el consumidor mandaba `cash_session_id = null` y la operación en efectivo se
 * registraba SIN movimiento de caja, en silencio.
 *
 * El hook ahora expone `isLoading` para distinguir «todavía no sé» de «no hay».
 * Mocks al mismo nivel que `use-cash-optin.test.ts`: los tres hooks de datos se
 * mockean directo (el flujo con TanStack real está en
 * `use-cash-optin-loading-real-queries.test.tsx`).
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { renderHook } from "@testing-library/react"
import { useCashOptin } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"

const useBranchesMock = vi.fn()
const useCashboxesMock = vi.fn()
const useCurrentSessionMock = vi.fn()

vi.mock("@/hooks/data/use-branches", () => ({ useBranches: () => useBranchesMock() }))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: (...args: unknown[]) => useCashboxesMock(...args),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (...args: unknown[]) => useCurrentSessionMock(...args),
}))

const BRANCHES = [{ id: "branch-1", name: "Sucursal 1" }]

afterEach(() => {
  vi.clearAllMocks()
})

describe("useCashOptin — isLoading mientras el kind es efectivo", () => {
  it("las cajas están cargando: isLoading=true y NO elegible (todavía no se sabe si hay sesión)", () => {
    useBranchesMock.mockReturnValue({ branches: BRANCHES, isLoading: false })
    useCashboxesMock.mockReturnValue({ data: undefined, isLoading: true })
    useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: false })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: argentinaToday(), document: "compra" }),
    )

    expect(result.current.isLoading).toBe(true)
    expect(result.current.eligible).toBe(false)
  })

  it("la sesión está cargando (cajas ya resueltas): isLoading=true y NO elegible", () => {
    useBranchesMock.mockReturnValue({ branches: BRANCHES, isLoading: false })
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }], isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: true })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: argentinaToday(), document: "compra" }),
    )

    expect(result.current.isLoading).toBe(true)
    expect(result.current.eligible).toBe(false)
    expect(result.current.session).toBeNull()
  })

  it("las sucursales están cargando y NO se eligió una: isLoading=true (sin sucursal efectiva no hay dónde buscar la caja)", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: true })
    useCashboxesMock.mockReturnValue({ data: undefined, isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: false })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: null, date: argentinaToday(), document: "venta" }),
    )

    expect(result.current.effectiveBranchId).toBeNull()
    expect(result.current.isLoading).toBe(true)
    expect(result.current.eligible).toBe(false)
  })

  it("las sucursales cargando pero la sucursal YA viene elegida: no espera por ellas (no las necesita)", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: true })
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-9" }], isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-9" }, isLoading: false })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-elegida", date: argentinaToday(), document: "venta" }),
    )

    expect(result.current.isLoading).toBe(false)
    expect(result.current.eligible).toBe(true)
  })

  it("requiresDate=false (cobro/pago): también expone la carga", () => {
    useBranchesMock.mockReturnValue({ branches: BRANCHES, isLoading: false })
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }], isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: true })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: null, date: "2000-01-01", document: "cobro", requiresDate: false }),
    )

    expect(result.current.isLoading).toBe(true)
    expect(result.current.eligible).toBe(false)
  })
})

describe("useCashOptin — isLoading=false cuando ya se resolvió (con y sin sesión)", () => {
  it("sesión presente: isLoading=false y elegible", () => {
    useBranchesMock.mockReturnValue({ branches: BRANCHES, isLoading: false })
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }], isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-abc" }, isLoading: false })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: argentinaToday(), document: "gasto" }),
    )

    expect(result.current.isLoading).toBe(false)
    expect(result.current.eligible).toBe(true)
  })

  it("sesión ausente (resuelta en null): isLoading=false, NO elegible y el motivo es el de caja cerrada — no se bloquea para siempre", () => {
    useBranchesMock.mockReturnValue({ branches: BRANCHES, isLoading: false })
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }], isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: null, isLoading: false })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: argentinaToday(), document: "gasto" }),
    )

    expect(result.current.isLoading).toBe(false)
    expect(result.current.eligible).toBe(false)
    expect(result.current.reason).toMatch(/no hay caja abierta/i)
  })

  it("sucursal sin caja (lista vacía resuelta): isLoading=false", () => {
    useBranchesMock.mockReturnValue({ branches: BRANCHES, isLoading: false })
    useCashboxesMock.mockReturnValue({ data: [], isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: false })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: argentinaToday(), document: "gasto" }),
    )

    expect(result.current.isLoading).toBe(false)
    expect(result.current.eligible).toBe(false)
  })

  it("fecha que no es hoy con la sesión resuelta: isLoading=false (el motivo es la fecha, no la espera)", () => {
    useBranchesMock.mockReturnValue({ branches: BRANCHES, isLoading: false })
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }], isLoading: false })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-abc" }, isLoading: false })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: "2020-01-02", document: "venta" }),
    )

    expect(result.current.isLoading).toBe(false)
    expect(result.current.eligible).toBe(false)
    expect(result.current.reason).toMatch(/fechada hoy/i)
  })
})

describe("useCashOptin — kind que no es efectivo no espera nada", () => {
  it("transfer: isLoading=false aunque los hooks mockeados digan que cargan (el hook sólo consulta con kind=cash)", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: true })
    useCashboxesMock.mockReturnValue({ data: undefined, isLoading: true })
    useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: true })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "transfer", branchId: null, date: argentinaToday(), document: "venta" }),
    )

    expect(result.current.isCashSelected).toBe(false)
    expect(result.current.isLoading).toBe(false)
  })

  it("sin forma de pago elegida (kind null): isLoading=false", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: true })
    useCashboxesMock.mockReturnValue({ data: undefined, isLoading: true })
    useCurrentSessionMock.mockReturnValue({ data: undefined, isLoading: true })

    const { result } = renderHook(() =>
      useCashOptin({ kind: null, branchId: null, date: argentinaToday() }),
    )

    expect(result.current.isLoading).toBe(false)
  })
})
