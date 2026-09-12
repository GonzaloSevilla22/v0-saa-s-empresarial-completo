/**
 * v3-rbac-multirole Parte C (grupo 17, D1) — useRoleCatalog() TDD tests.
 *
 * Etiquetas y descripciones SALEN del catálogo (account_role_catalog),
 * nunca de un objeto hardcodeado en la pantalla.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const state = {
  rows: [] as unknown[],
  error: null as { message: string } | null,
  lastOrderCol: "" as string,
}

function makeBuilder() {
  const builder = {
    select: vi.fn(() => builder),
    order: vi.fn((col: string) => {
      state.lastOrderCol = col
      return builder
    }),
    then(onFulfilled: (v: { data: unknown; error: unknown }) => unknown) {
      return Promise.resolve(onFulfilled({ data: state.error ? null : state.rows, error: state.error }))
    },
  }
  return builder
}

vi.mock("@/lib/supabase/client", () => ({
  createClient: vi.fn(() => ({
    from: vi.fn(() => makeBuilder()),
  })),
}))

import { useRoleCatalog, resolveRoleLabel, type RoleCatalogEntry } from "@/hooks/data/use-role-catalog"

const CATALOG: RoleCatalogEntry[] = [
  { code: "owner", label: "Propietario", description: "d1", sort_order: 1, is_writer: true },
  { code: "viewer", label: "Observador", description: "d2", sort_order: 8, is_writer: false },
]

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

describe("useRoleCatalog", () => {
  beforeEach(() => {
    state.rows = [...CATALOG]
    state.error = null
  })

  it("RED: trae el catálogo ordenado por sort_order", async () => {
    const { result } = renderHook(() => useRoleCatalog(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.data).toEqual(CATALOG)
    expect(state.lastOrderCol).toBe("sort_order")
  })

  it("resolveRoleLabel resuelve la etiqueta del catálogo, no un texto hardcodeado", () => {
    expect(resolveRoleLabel(CATALOG, "owner")).toBe("Propietario")
    expect(resolveRoleLabel(CATALOG, "viewer")).toBe("Observador")
  })

  it("resolveRoleLabel cae al código crudo si el catálogo no cargó todavía", () => {
    expect(resolveRoleLabel(undefined, "seller")).toBe("seller")
  })
})
