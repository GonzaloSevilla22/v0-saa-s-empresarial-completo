/**
 * Tests del hook `useCashOptin` (frontend/hooks/use-cash-optin.ts) —
 * caja-compras-cobranzas (task 9.2 TRIANGULATE).
 *
 * El hook ya tenía cobertura indirecta vía sale-form-cash-optin-baseline.test.tsx
 * (documento "venta") y expense-form-v2 (documento "gasto"). Este archivo
 * agrega los dos consumidores nuevos de este change:
 *   · document="compra" — el motivo de fecha nombra "una compra fechada hoy".
 *   · document="cobro" con requiresDate=false — el motivo de fecha NUNCA se
 *     usa, porque el cobro/pago no tiene fecha propia (D5). Se verifica que
 *     la condición de fecha queda vacuamente cumplida y que el hook es
 *     elegible con sólo kind=cash + sesión abierta (dos condiciones, no tres).
 *
 * Mocks al mismo nivel que el baseline: los tres hooks de datos que
 * useCashOptin consume (useBranches/useCashboxes/useCurrentSession) se
 * mockean directo — no hace falta un QueryClientProvider real.
 */
import { describe, it, expect, vi, afterEach } from "vitest"
import { renderHook } from "@testing-library/react"
import { useCashOptin } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"

const useCashboxesMock = vi.fn()
const useCurrentSessionMock = vi.fn()

vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => ({ branches: [{ id: "branch-1", name: "Sucursal 1" }] }),
}))
vi.mock("@/hooks/data/use-cashboxes", () => ({
  useCashboxes: (...args: unknown[]) => useCashboxesMock(...args),
}))
vi.mock("@/hooks/data/use-cash-session", () => ({
  useCurrentSession: (...args: unknown[]) => useCurrentSessionMock(...args),
}))

afterEach(() => {
  vi.clearAllMocks()
})

describe("useCashOptin — document='compra'", () => {
  it("las tres condiciones cumplidas: eligible=true, sesión expuesta", () => {
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-abc" } })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: argentinaToday(), document: "compra" })
    )

    expect(result.current.eligible).toBe(true)
    expect(result.current.session?.id).toBe("session-abc")
  })

  it("fecha anterior a hoy: el motivo nombra 'una compra fechada hoy'", () => {
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-abc" } })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: "2020-01-02", document: "compra" })
    )

    expect(result.current.eligible).toBe(false)
    expect(result.current.reason).toMatch(/compra fechada hoy/i)
  })

  it("sin sesión abierta: el motivo es el de caja cerrada, no el de fecha", () => {
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
    useCurrentSessionMock.mockReturnValue({ data: null })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: argentinaToday(), document: "compra" })
    )

    expect(result.current.eligible).toBe(false)
    expect(result.current.reason).toMatch(/no hay caja abierta/i)
  })
})

describe("useCashOptin — document='cobro', requiresDate=false (D5, dos condiciones)", () => {
  it("kind=cash + sesión abierta ES elegible aunque la 'fecha' sea antigua — la condición de fecha no aplica", () => {
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-xyz" } })

    const { result } = renderHook(() =>
      useCashOptin({
        kind: "cash",
        branchId: null,
        date: "2000-01-01", // deliberadamente vieja: no debe importar
        document: "cobro",
        requiresDate: false,
      })
    )

    expect(result.current.isDateToday).toBe(true) // vacuamente cumplida
    expect(result.current.eligible).toBe(true)
  })

  it("sin sesión abierta: el motivo sigue siendo el de caja cerrada (nunca el de fecha)", () => {
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
    useCurrentSessionMock.mockReturnValue({ data: null })

    const { result } = renderHook(() =>
      useCashOptin({
        kind: "cash",
        branchId: null,
        date: "2000-01-01",
        document: "cobro",
        requiresDate: false,
      })
    )

    expect(result.current.eligible).toBe(false)
    expect(result.current.reason).toMatch(/no hay caja abierta/i)
  })

  it("kind no efectivo: no elegible, motivo de 'sólo efectivo' — igual que el resto de los documentos", () => {
    useCashboxesMock.mockReturnValue({ data: [] })
    useCurrentSessionMock.mockReturnValue({ data: null })

    const { result } = renderHook(() =>
      useCashOptin({
        kind: "transfer",
        branchId: null,
        date: "2000-01-01",
        document: "cobro",
        requiresDate: false,
      })
    )

    expect(result.current.isCashSelected).toBe(false)
    expect(result.current.eligible).toBe(false)
    expect(result.current.reason).toMatch(/efectivo/i)
  })
})

describe("useCashOptin — requiresDate default (retrocompatibilidad)", () => {
  it("sin pasar requiresDate, el default sigue siendo true (venta/gasto/compra no cambian)", () => {
    useCashboxesMock.mockReturnValue({ data: [{ id: "cashbox-1" }] })
    useCurrentSessionMock.mockReturnValue({ data: { id: "session-abc" } })

    const { result } = renderHook(() =>
      useCashOptin({ kind: "cash", branchId: "branch-1", date: "2000-01-01", document: "venta" })
    )

    expect(result.current.isDateToday).toBe(false)
    expect(result.current.eligible).toBe(false)
  })
})
