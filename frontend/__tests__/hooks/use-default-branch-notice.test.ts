/**
 * Tests de `useDefaultBranchNotice` (frontend/hooks/use-default-branch-notice.ts)
 * — sucursal-guard-vaciado-auditoria, OQ-6.
 *
 * `useBranches()` se mockea directo (mismo nivel que use-cash-optin.test.ts):
 * el hook bajo test no le pide nada más que `branches`/`isLoading`, y ya
 * devuelve las sucursales activas ordenadas por `created_at ASC` — por eso
 * la primera OPERATIVA de la lista hace de "sucursal por defecto"
 * (`resolveDefaultBranch`, espejo de `c26_default_branch`; ventas-sucursal-por-defecto
 * D10: antes se tomaba `branches[0]` aunque estuviera cerrada).
 */
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { renderHook } from "@testing-library/react"
import { useDefaultBranchNotice } from "@/hooks/use-default-branch-notice"

const useBranchesMock = vi.fn()
const toastInfoMock = vi.fn()

vi.mock("@/hooks/data/use-branches", () => ({
  useBranches: () => useBranchesMock(),
}))
vi.mock("sonner", () => ({
  toast: { info: (...args: unknown[]) => toastInfoMock(...args) },
}))

const SEEN_KEY = "eie_default_branch_seen"

const branchA = { id: "branch-a", name: "Sucursal Centro" }
const branchB = { id: "branch-b", name: "Sucursal Showroom" }

describe("useDefaultBranchNotice", () => {
  beforeEach(() => {
    sessionStorage.clear()
  })

  afterEach(() => {
    vi.clearAllMocks()
  })

  it("sin valor previo en sessionStorage: no muestra el toast, sólo persiste", () => {
    useBranchesMock.mockReturnValue({ branches: [branchA], isLoading: false })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).not.toHaveBeenCalled()
    expect(sessionStorage.getItem(SEEN_KEY)).toBe("branch-a")
  })

  it("mismo id que el valor previo: no muestra el toast", () => {
    sessionStorage.setItem(SEEN_KEY, "branch-a")
    useBranchesMock.mockReturnValue({ branches: [branchA], isLoading: false })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).not.toHaveBeenCalled()
    expect(sessionStorage.getItem(SEEN_KEY)).toBe("branch-a")
  })

  it("id distinto del valor previo: muestra el toast con el nombre de la nueva sucursal por defecto y persiste el nuevo id", () => {
    sessionStorage.setItem(SEEN_KEY, "branch-a")
    useBranchesMock.mockReturnValue({ branches: [branchB], isLoading: false })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).toHaveBeenCalledTimes(1)
    expect(toastInfoMock).toHaveBeenCalledWith("Tu sucursal por defecto ahora es Sucursal Showroom")
    expect(sessionStorage.getItem(SEEN_KEY)).toBe("branch-b")
  })

  it("mientras isLoading es true no compara ni persiste todavía", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: true })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).not.toHaveBeenCalled()
    expect(sessionStorage.getItem(SEEN_KEY)).toBeNull()
  })

  it("la más antigua CERRADA no se anuncia como principal: se anuncia la siguiente operativa (ventas-sucursal-por-defecto D10)", () => {
    sessionStorage.setItem(SEEN_KEY, "branch-zz")
    const cerrada = { id: "branch-cerrada", name: "Depósito viejo", isActive: true, status: "closed" }
    const operativa = { id: "branch-op", name: "Sucursal Centro", isActive: true, status: "active" }
    useBranchesMock.mockReturnValue({ branches: [cerrada, operativa], isLoading: false })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).toHaveBeenCalledTimes(1)
    expect(toastInfoMock).toHaveBeenCalledWith("Tu sucursal por defecto ahora es Sucursal Centro")
    expect(sessionStorage.getItem(SEEN_KEY)).toBe("branch-op")
  })

  it("la principal operativa no cambió aunque se cierre otra sucursal posterior: no hay aviso", () => {
    sessionStorage.setItem(SEEN_KEY, "branch-op")
    const operativa = { id: "branch-op", name: "Sucursal Centro", isActive: true, status: "active" }
    const cerradaTarde = { id: "branch-tarde", name: "Showroom", isActive: true, status: "closed" }
    useBranchesMock.mockReturnValue({ branches: [operativa, cerradaTarde], isLoading: false })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).not.toHaveBeenCalled()
  })

  it("cuenta sin sucursales activas: no rompe, no persiste", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: false })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).not.toHaveBeenCalled()
    expect(sessionStorage.getItem(SEEN_KEY)).toBeNull()
  })
})
