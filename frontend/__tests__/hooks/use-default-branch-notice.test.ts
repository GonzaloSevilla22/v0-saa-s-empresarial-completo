/**
 * Tests de `useDefaultBranchNotice` (frontend/hooks/use-default-branch-notice.ts)
 * — sucursal-guard-vaciado-auditoria, OQ-6.
 *
 * `useBranches()` se mockea directo (mismo nivel que use-cash-optin.test.ts):
 * el hook bajo test no le pide nada más que `branches`/`isLoading`, y ya
 * devuelve las sucursales activas ordenadas por `created_at ASC` — por eso
 * `branches[0]` en los fixtures de abajo hace de "sucursal por defecto".
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

  it("cuenta sin sucursales activas: no rompe, no persiste", () => {
    useBranchesMock.mockReturnValue({ branches: [], isLoading: false })

    renderHook(() => useDefaultBranchNotice())

    expect(toastInfoMock).not.toHaveBeenCalled()
    expect(sessionStorage.getItem(SEEN_KEY)).toBeNull()
  })
})
