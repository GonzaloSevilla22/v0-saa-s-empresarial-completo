/**
 * presupuestos-modulo (D11, task 4.8) — `useOrgRole` expone `rolesResolved`.
 *
 * Mientras el conjunto de roles activos carga, `roles` vale `[role]` y `role`
 * colapsa a `member` a un usuario que sólo es vendedor
 * (`rpc_my_account_role` sólo devuelve owner | admin | member). Decidir una
 * capacidad sobre ese array de conveniencia sería fail-CLOSED y le ocultaría el
 * módulo al usuario principal: el hook necesita decir si el conjunto ya
 * resolvió para que `hasCapability` falle abierto mientras tanto.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const state = {
  roleResult: "member" as unknown,
  activeRolesResult: undefined as unknown, // undefined = nunca resuelve (cargando)
  activeRolesError: null as { message: string } | null,
}

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acc-1" } }),
}))

function catalogBuilder() {
  const builder = {
    select: vi.fn(() => builder),
    order: vi.fn(() => builder),
    then(onFulfilled: (v: { data: unknown; error: unknown }) => unknown) {
      return Promise.resolve(onFulfilled({ data: [], error: null }))
    },
  }
  return builder
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    rpc: vi.fn((fnName: string) => {
      if (fnName === "rpc_my_active_account_roles") {
        if (state.activeRolesResult === undefined) return new Promise(() => {})
        return Promise.resolve({ data: state.activeRolesResult, error: state.activeRolesError })
      }
      return Promise.resolve({ data: state.roleResult, error: null })
    }),
    from: vi.fn(() => catalogBuilder()),
  })),
}))

import { useOrgRole } from "@/hooks/useOrgRole"

function render() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return renderHook(() => useOrgRole(), { wrapper })
}

beforeEach(() => {
  state.roleResult = "member"
  state.activeRolesResult = undefined
  state.activeRolesError = null
})

describe("useOrgRole — rolesResolved", () => {
  it("mientras el conjunto carga: rolesResolved=false y roles es el array de conveniencia", async () => {
    const { result } = render()
    // Deja que asiente todo lo que sí resuelve (el singular y el catálogo).
    await act(async () => {
      await Promise.resolve()
    })
    expect(result.current.rolesResolved).toBe(false)
  })

  it("conjunto resuelto con un vendedor: rolesResolved=true y roles=['seller'] (aunque role sea member)", async () => {
    state.activeRolesResult = ["seller"]
    const { result } = render()
    await waitFor(() => expect(result.current.rolesResolved).toBe(true))
    expect(result.current.roles).toEqual(["seller"])
  })

  it("conjunto resuelto y genuinamente vacío: rolesResolved=true y roles=[] (no cae al fallback)", async () => {
    state.activeRolesResult = []
    const { result } = render()
    await waitFor(() => expect(result.current.rolesResolved).toBe(true))
    expect(result.current.roles).toEqual([])
  })

  it("error al resolver el conjunto: sigue sin resolver (fail-open, igual que isWriter)", async () => {
    state.activeRolesResult = null
    state.activeRolesError = { message: "boom" }
    const { result } = render()
    await act(async () => {
      await new Promise((r) => setTimeout(r, 20))
    })
    expect(result.current.rolesResolved).toBe(false)
    expect(result.current.isWriter).toBe(true)
  })

  it("no cambia el resto de la forma del hook", async () => {
    state.activeRolesResult = ["owner", "cashier"]
    const { result } = render()
    await waitFor(() => expect(result.current.rolesResolved).toBe(true))
    expect(Object.keys(result.current).sort()).toEqual(["isLoading", "isWriter", "role", "roles", "rolesResolved"])
  })
})
