/**
 * useSuppliers — listado + alta + edición + baja (compras-proveedor-cuenta-corriente,
 * task 10.1). Espejo exacto de useClients (D10 del design: mismo pythonClient, mismo
 * patrón de mappers snake_case → camelCase, misma invalidación por queryKeys).
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useSuppliers } from "@/hooks/data/use-suppliers"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

beforeEach(() => vi.clearAllMocks())

describe("useSuppliers — listado", () => {
  it("returns mapped suppliers from GET /suppliers", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([
      {
        id: "s-1", account_id: "acc-1", name: "Distribuidora Mendoza",
        tax_id: "20-12345678-6", iva_condition: "responsable_inscripto",
        legal_name: "Distribuidora Mendoza SRL", email: "contacto@dm.com", phone: "2615551234",
        created_at: "2026-08-01T00:00:00Z",
      },
    ])

    const { result } = renderHook(() => useSuppliers(), { wrapper: makeWrapper() })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledWith("/suppliers")
    expect(result.current.suppliers).toHaveLength(1)
    expect(result.current.suppliers[0]).toMatchObject({
      id:           "s-1",
      name:         "Distribuidora Mendoza",
      taxId:        "20-12345678-6",
      ivaCondition: "responsable_inscripto",
      legalName:    "Distribuidora Mendoza SRL",
      email:        "contacto@dm.com",
      phone:        "2615551234",
    })
  })

  it("un proveedor solo con nombre mapea los atributos fiscales como undefined", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce([
      { id: "s-2", account_id: "acc-1", name: "Solo Nombre", created_at: "2026-08-01T00:00:00Z" },
    ])

    const { result } = renderHook(() => useSuppliers(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.suppliers[0]).toMatchObject({
      id: "s-2", name: "Solo Nombre",
      taxId: undefined, ivaCondition: undefined, legalName: undefined,
    })
  })
})

describe("useSuppliers — alta", () => {
  it("addSupplier llama a POST /suppliers e invalida la cache", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      id: "s-new", account_id: "acc-1", name: "Nuevo Proveedor", created_at: "2026-08-20T00:00:00Z",
    })

    const { result } = renderHook(() => useSuppliers(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.addSupplier({ name: "Nuevo Proveedor", email: "", phone: "" })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/suppliers", {
      name: "Nuevo Proveedor", email: null, phone: null,
      tax_id: null, iva_condition: null, legal_name: null,
    })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalledTimes(2))
  })
})

describe("useSuppliers — edición", () => {
  it("updateSupplier llama a PUT /suppliers/{id} con los campos fiscales", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.put).mockResolvedValueOnce({
      id: "s-1", account_id: "acc-1", name: "Editado", created_at: "2026-08-01T00:00:00Z",
    })

    const { result } = renderHook(() => useSuppliers(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.updateSupplier({
        id: "s-1", name: "Editado", email: "", phone: "",
        taxId: "20-12345678-6", ivaCondition: "monotributista", legalName: "Editado SRL",
      })
    })

    expect(pythonClient.put).toHaveBeenCalledWith("/suppliers/s-1", {
      name: "Editado", email: null, phone: null,
      tax_id: "20-12345678-6", iva_condition: "monotributista", legal_name: "Editado SRL",
    })
  })
})

describe("useSuppliers — baja", () => {
  it("deleteSupplier llama a DELETE /suppliers/{id} e invalida la cache", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue([])
    vi.mocked(pythonClient.delete).mockResolvedValueOnce(undefined)

    const { result } = renderHook(() => useSuppliers(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deleteSupplier("s-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/suppliers/s-1")
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalledTimes(2))
  })
})
