/**
 * v3-rbac-multirole Parte C (grupo 17) — useMembers() TDD tests.
 *
 * Cycle: RED → GREEN. Mock: @/lib/api/python-client.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    patch: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useMembers } from "@/hooks/data/use-members"
import { queryKeys } from "@/lib/query-keys"

const ACCOUNT_ID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
const USER_ID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

const MEMBER_ROW = {
  member_id: "cccccccc-cccc-cccc-cccc-cccccccccccc",
  user_id: USER_ID,
  legacy_role: "member",
  created_at: "2026-09-01T10:00:00+00:00",
  name: "Ana",
  email: "ana@test.local",
  roles: [{ role: "seller", expires_at: null, is_active: true }],
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return {
    Wrapper: ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children),
    queryClient,
  }
}

describe("useMembers", () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  it("RED: lista los miembros vía GET /members", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([MEMBER_ROW])
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useMembers(ACCOUNT_ID), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledWith("/members")
    expect(result.current.members).toEqual([MEMBER_ROW])
  })

  it("no consulta si no hay accountId activo", () => {
    const { Wrapper } = makeWrapper()

    renderHook(() => useMembers(null), { wrapper: Wrapper })

    expect(pythonClient.get).not.toHaveBeenCalled()
  })

  it("assignRole llama POST /members/{userId}/roles con el payload correcto", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.post).mockResolvedValue({ account_id: ACCOUNT_ID, user_id: USER_ID, role: "seller", expires_at: null })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useMembers(ACCOUNT_ID), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.assignRole({ userId: USER_ID, role: "seller", expiresAt: null })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(`/members/${USER_ID}/roles`, { role: "seller", expires_at: null })
  })

  it("assignRole con vencimiento pasa expires_at", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.post).mockResolvedValue({})
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useMembers(ACCOUNT_ID), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.assignRole({ userId: USER_ID, role: "cashier", expiresAt: "2026-12-01T00:00:00.000Z" })
    })

    expect(pythonClient.post).toHaveBeenCalledWith(`/members/${USER_ID}/roles`, {
      role: "cashier",
      expires_at: "2026-12-01T00:00:00.000Z",
    })
  })

  it("revokeRole llama DELETE /members/{userId}/roles/{role}", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.delete).mockResolvedValue({})
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useMembers(ACCOUNT_ID), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.revokeRole({ userId: USER_ID, role: "seller" })
    })

    expect(pythonClient.delete).toHaveBeenCalledWith(`/members/${USER_ID}/roles/seller`)
  })

  it("removeMember llama DELETE /members/{userId}", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.delete).mockResolvedValue({ ok: true })
    const { Wrapper } = makeWrapper()

    const { result } = renderHook(() => useMembers(ACCOUNT_ID), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.removeMember(USER_ID)
    })

    expect(pythonClient.delete).toHaveBeenCalledWith(`/members/${USER_ID}`)
  })

  it("TRIANGULATE: assignRole invalida el listado de miembros (clave exacta) tras el éxito", async () => {
    // Ronda 1 adversarial (finding NIT): antes sólo se verificaba
    // `toHaveBeenCalled()` -- una regresión que invalidara SÓLO "orgRole"
    // (justo la clave que NO refresca el listado) habría dejado este test
    // en verde igual. Se assertea la clave concreta del listado.
    vi.mocked(pythonClient.get).mockResolvedValue([MEMBER_ROW])
    vi.mocked(pythonClient.post).mockResolvedValue({})
    const { Wrapper, queryClient } = makeWrapper()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useMembers(ACCOUNT_ID), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.assignRole({ userId: USER_ID, role: "seller", expiresAt: null })
    })

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: queryKeys.members.list(ACCOUNT_ID) })
    // Ronda 2 adversarial (finding MINOR): "orgActiveRoles" es la clave de
    // la que useOrgRole.ts deriva isWriter (el CONJUNTO real, desde la
    // ronda 1) -- sin invalidarla, un owner/admin que se asigna un rol a sí
    // mismo seguía viendo el conjunto viejo hasta 5 minutos o un reload.
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["orgActiveRoles", ACCOUNT_ID] })
  })

  it("TRIANGULATE: revokeRole invalida el listado de miembros (clave exacta) tras el éxito", async () => {
    // Ronda 1 adversarial (finding NIT): caso espejo -- revokeRole no tenía
    // NINGÚN test de invalidación (sólo assignRole lo tenía, y de forma
    // laxa).
    vi.mocked(pythonClient.get).mockResolvedValue([MEMBER_ROW])
    vi.mocked(pythonClient.delete).mockResolvedValue({})
    const { Wrapper, queryClient } = makeWrapper()
    const invalidateSpy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useMembers(ACCOUNT_ID), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.revokeRole({ userId: USER_ID, role: "seller" })
    })

    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: queryKeys.members.list(ACCOUNT_ID) })
    // Ronda 2 adversarial (finding MINOR): mismo criterio que assignRole
    // arriba -- espejo del lado revoke.
    expect(invalidateSpy).toHaveBeenCalledWith({ queryKey: ["orgActiveRoles", ACCOUNT_ID] })
  })
})
