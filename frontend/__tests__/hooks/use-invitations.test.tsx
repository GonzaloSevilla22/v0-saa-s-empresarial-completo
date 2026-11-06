/**
 * invitaciones-hardening (D5, D6) — el token de invitación viaja en el CUERPO de la API, nunca en su ruta.
 *
 *   useInvitationPreview(token)  -> POST /invitations/preview  { token }
 *   useAcceptInvitation(token)   -> POST /invitations/accept   { token }
 *
 * La URL pública /invitacion/<token> se conserva (decisión del PO); lo que cambia es cómo habla la pantalla con
 * FastAPI: el access log de Render registra el path, no el cuerpo. La clave de caché de la vista previa tampoco
 * lleva el token en claro.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

const h = vi.hoisted(() => ({ get: vi.fn(), post: vi.fn() }))

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: (...a: unknown[]) => h.get(...a), post: (...a: unknown[]) => h.post(...a), delete: vi.fn() },
}))

import { useAcceptInvitation, useInvitationPreview } from "@/hooks/data/use-invitations"
import { queryKeys } from "@/lib/query-keys"

const TOKEN = "0123456789abcdef".repeat(4)
const OTHER = "fedcba9876543210".repeat(4)

function wrapperWith(client: QueryClient) {
  return function Wrapper({ children }: { children: React.ReactNode }) {
    return <QueryClientProvider client={client}>{children}</QueryClientProvider>
  }
}

beforeEach(() => {
  h.get.mockReset()
  h.post.mockReset().mockResolvedValue({ account_id: "a", account_member_id: "m", active_account_id: "a", role: "member", roles: ["seller"] })
})

describe("useInvitationPreview", () => {
  it("pide la vista previa por POST con el token en el cuerpo y NO en la ruta", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const { result } = renderHook(() => useInvitationPreview(TOKEN, true), { wrapper: wrapperWith(client) })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(h.post).toHaveBeenCalledTimes(1)
    expect(h.post).toHaveBeenCalledWith("/invitations/preview", { token: TOKEN })
    expect(h.get).not.toHaveBeenCalled()
    const [path] = h.post.mock.calls[0]
    expect(String(path)).not.toContain(TOKEN)
    expect(String(path)).not.toContain(encodeURIComponent(TOKEN))
  })

  it("no consulta nada sin sesión (enabled=false)", async () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    renderHook(() => useInvitationPreview(TOKEN, false), { wrapper: wrapperWith(client) })
    await new Promise((r) => setTimeout(r, 20))
    expect(h.post).not.toHaveBeenCalled()
  })

  it("no reintenta ante un 404 (una sola consulta con el token)", async () => {
    h.post.mockRejectedValue(new Error("404"))
    const client = new QueryClient({ defaultOptions: { queries: { retry: 3 } } })
    const { result } = renderHook(() => useInvitationPreview(TOKEN, true), { wrapper: wrapperWith(client) })
    await waitFor(() => expect(result.current.isError).toBe(true))
    expect(h.post).toHaveBeenCalledTimes(1)
  })
})

describe("useAcceptInvitation", () => {
  it("acepta por POST con el token en el cuerpo y NO en la ruta", async () => {
    const client = new QueryClient({ defaultOptions: { mutations: { retry: false } } })
    const { result } = renderHook(() => useAcceptInvitation(TOKEN), { wrapper: wrapperWith(client) })
    await act(async () => {
      await result.current.mutateAsync()
    })
    expect(h.post).toHaveBeenCalledWith("/invitations/accept", { token: TOKEN })
    const [path] = h.post.mock.calls[0]
    expect(String(path)).not.toContain(TOKEN)
  })
})

describe("queryKeys.invitations.preview", () => {
  it("no incluye el token en claro y distingue dos tokens distintos", () => {
    const a = queryKeys.invitations.preview(TOKEN)
    const b = queryKeys.invitations.preview(OTHER)
    expect(JSON.stringify(a)).not.toContain(TOKEN)
    expect(JSON.stringify(a)).not.toContain(TOKEN.slice(0, 16))
    expect(JSON.stringify(a)).not.toBe(JSON.stringify(b))
    // Determinístico: el mismo token da la misma clave (la caché de una pantalla es estable).
    expect(queryKeys.invitations.preview(TOKEN)).toEqual(a)
  })
})
