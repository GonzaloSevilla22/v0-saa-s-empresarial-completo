/**
 * remitos-venta (D11, tarea 4.8) — `hooks/data/use-client-addresses.ts`:
 * `GET /clients/{id}/addresses` (que el backend ya expone desde
 * `v3-catalog-masters`) mapeado a camelCase. Lo usa el domicilio de entrega
 * precargado del remito. Grep previo: no había ningún hook ni cliente API de
 * direcciones, sólo el tipo `ClientAddress` en `lib/types.ts`.
 *
 * Mock: `@/lib/api/python-client`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useClientAddresses } from "@/hooks/data/use-client-addresses"
import { queryKeys } from "@/lib/query-keys"

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { queryClient, wrapper }
}

const ROW = {
  id: "addr-1",
  account_id: "acc-1",
  client_id: "c-1",
  alias: "Casa",
  street: "San Martín 100",
  city: "Mendoza",
  province: "Mendoza",
  postal_code: "5500",
  notes: "Timbre 2",
  is_primary: true,
  created_at: "2026-09-01T10:00:00Z",
  updated_at: null,
}

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(pythonClient.get).mockResolvedValue([ROW])
})

describe("useClientAddresses", () => {
  it("pide GET /clients/{id}/addresses y mapea snake_case al tipo ClientAddress", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useClientAddresses("c-1"), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(pythonClient.get).toHaveBeenCalledWith("/clients/c-1/addresses")
    expect(result.current.data).toEqual([
      {
        id: "addr-1",
        accountId: "acc-1",
        clientId: "c-1",
        alias: "Casa",
        street: "San Martín 100",
        city: "Mendoza",
        province: "Mendoza",
        postalCode: "5500",
        notes: "Timbre 2",
        isPrimary: true,
        createdAt: "2026-09-01T10:00:00Z",
        updatedAt: null,
      },
    ])
  })

  it("sin cliente elegido no consulta nada", () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useClientAddresses(null), { wrapper })
    expect(pythonClient.get).not.toHaveBeenCalled()
    expect(result.current.data).toBeUndefined()
  })

  it("el id del cliente se escapa en la ruta", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useClientAddresses("a/b"), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/clients/a%2Fb/addresses")
  })

  it("un cliente sin direcciones devuelve la lista vacía", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    const { wrapper } = setup()
    const { result } = renderHook(() => useClientAddresses("c-2"), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(result.current.data).toEqual([])
  })

  it("cada cliente tiene su propia clave de caché, bajo el prefijo 'clients' (se invalida con el resto)", async () => {
    const { queryClient, wrapper } = setup()
    const a = renderHook(() => useClientAddresses("c-1"), { wrapper })
    const b = renderHook(() => useClientAddresses("c-2"), { wrapper })
    await waitFor(() => expect(a.result.current.isSuccess && b.result.current.isSuccess).toBe(true))

    expect(queryKeys.clients.addresses("c-1")).toEqual(["clients", "addresses", "c-1"])
    expect(queryClient.getQueryState(queryKeys.clients.addresses("c-1"))).toBeDefined()
    expect(queryClient.getQueryState(queryKeys.clients.addresses("c-2"))).toBeDefined()
    expect(queryKeys.clients.addresses("c-1")[0]).toBe(queryKeys.clients.all()[0])
  })
})
