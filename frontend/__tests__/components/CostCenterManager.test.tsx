/**
 * CostCenterManager — component tests (fix/payment-method-reactivate).
 * Setup tomado de PaymentMethodManager.test.tsx: useOrgRole mockeado por caso
 * (member vs owner).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import userEvent from "@testing-library/user-event"
import { CostCenterManager } from "@/components/cost-centers/CostCenterManager"
import { toast } from "sonner"
import type { CostCenter } from "@/lib/types"

vi.mock("sonner", () => ({
  toast: { success: vi.fn(), error: vi.fn() },
}))

const CENTERS: CostCenter[] = [
  { id: "cc-log", accountId: "a", name: "Logística", code: "LOG", isActive: true, createdAt: "2026-08-19T00:00:00Z" },
  { id: "cc-mkt", accountId: "a", name: "Marketing", code: "MKT", isActive: false, createdAt: "2026-08-19T00:00:00Z" },
]

const useCostCentersMock = vi.fn()
vi.mock("@/hooks/data/use-cost-centers", () => ({
  useCostCenters: (...args: unknown[]) => useCostCentersMock(...args),
}))

const useOrgRoleMock = vi.fn()
vi.mock("@/hooks/useOrgRole", () => ({
  useOrgRole: () => useOrgRoleMock(),
}))

function baseHookReturn(overrides: Partial<ReturnType<typeof defaultHookReturn>> = {}) {
  return { ...defaultHookReturn(), ...overrides }
}

function defaultHookReturn() {
  return {
    costCenters: CENTERS,
    isLoading: false,
    createCostCenter: vi.fn(),
    updateCostCenter: vi.fn(),
    deactivateCostCenter: vi.fn(),
    reactivateCostCenter: vi.fn().mockResolvedValue(undefined),
    createCostCenterMutation: { isPending: false },
    updateCostCenterMutation: { isPending: false },
    deactivateCostCenterMutation: { isPending: false },
    reactivateCostCenterMutation: { isPending: false },
  }
}

describe("CostCenterManager — gating por rol", () => {
  beforeEach(() => {
    useCostCentersMock.mockReturnValue(baseHookReturn())
  })

  it("member: NO ve el botón 'Nuevo' ni las acciones de editar/desactivar", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    render(<CostCenterManager />)

    expect(screen.queryByText("Nuevo")).not.toBeInTheDocument()
    expect(screen.queryByTitle("Editar")).not.toBeInTheDocument()
    expect(screen.queryByTitle("Desactivar")).not.toBeInTheDocument()
  })

  it("owner: SÍ ve el botón 'Nuevo' y las acciones de editar/desactivar", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<CostCenterManager />)

    expect(screen.getByText("Nuevo")).toBeInTheDocument()
    expect(screen.getByTitle("Editar")).toBeInTheDocument()
    expect(screen.getByTitle("Desactivar")).toBeInTheDocument()
  })

  it("un centro inactivo se muestra con badge 'Inactivo'", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<CostCenterManager />)

    expect(screen.getByText("Inactivo")).toBeInTheDocument()
  })
})

describe("CostCenterManager — reactivar (fix/payment-method-reactivate)", () => {
  beforeEach(() => {
    useCostCentersMock.mockReturnValue(baseHookReturn())
  })

  it("owner: una fila inactiva muestra el botón 'Reactivar' y NO los de Editar/Desactivar", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<CostCenterManager />)

    expect(screen.getByRole("button", { name: "Reactivar Marketing" })).toBeInTheDocument()
    // Precondición sin la cual el botón nunca se vería: el gestor pide la
    // lista CON inactivos (el selector operativo pide sólo activos).
    expect(useCostCentersMock).toHaveBeenCalledWith(true)
    expect(screen.getAllByTitle("Editar")).toHaveLength(1)
    expect(screen.getAllByTitle("Desactivar")).toHaveLength(1)
  })

  it("owner: click en 'Reactivar' llama a reactivateCostCenter con el id y muestra el toast de éxito", async () => {
    const reactivateCostCenter = vi.fn().mockResolvedValue(undefined)
    useCostCentersMock.mockReturnValue(baseHookReturn({ reactivateCostCenter }))
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    const user = userEvent.setup()
    render(<CostCenterManager />)

    await user.click(screen.getByRole("button", { name: "Reactivar Marketing" }))

    expect(reactivateCostCenter).toHaveBeenCalledWith("cc-mkt")
    expect(toast.success).toHaveBeenCalledWith('"Marketing" reactivado')
  })

  it("owner: si reactivar falla, muestra toast de error", async () => {
    const reactivateCostCenter = vi.fn().mockRejectedValue(new Error("boom"))
    useCostCentersMock.mockReturnValue(baseHookReturn({ reactivateCostCenter }))
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    const user = userEvent.setup()
    render(<CostCenterManager />)

    await user.click(screen.getByRole("button", { name: "Reactivar Marketing" }))

    expect(toast.error).toHaveBeenCalledWith("Error al reactivar: boom")
  })

  it("una fila activa NO muestra el botón 'Reactivar'", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: true, role: "owner", isLoading: false })

    render(<CostCenterManager />)

    expect(screen.queryByRole("button", { name: "Reactivar Logística" })).not.toBeInTheDocument()
  })

  it("member: no ve el botón 'Reactivar' en una fila inactiva", () => {
    useOrgRoleMock.mockReturnValue({ isWriter: false, role: "member", isLoading: false })

    render(<CostCenterManager />)

    expect(screen.queryByRole("button", { name: "Reactivar Marketing" })).not.toBeInTheDocument()
  })
})
