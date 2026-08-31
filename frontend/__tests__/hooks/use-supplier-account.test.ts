/**
 * qa-integral-modulos (G9, task 9.5 — H22): useSupplierAccount degrada el 404
 * de cuenta inexistente a `null` (estado "sin cuenta aún"), en lugar de dejar
 * que la página lo pinte como banner destructivo. Mismo trato que ya le da el
 * formulario de compra (ignora el error y asume $0). Un error REAL (500, red)
 * sigue subiendo como error de la query.
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get: vi.fn(),
    post: vi.fn(),
    put: vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useSupplierAccount } from "@/hooks/data/use-supplier-account"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

const ACCOUNT_API = {
  id: "sa-1",
  account_id: "acct-1",
  supplier_id: "sup-1",
  balance: "116550.00",
  created_at: "2026-08-01T00:00:00Z",
  movements: [],
}

describe("useSupplierAccount — 404 de cuenta inexistente (H22)", () => {
  beforeEach(() => vi.clearAllMocks())

  it("RED: el 404 'Cuenta corriente no encontrada' degrada a data null SIN error", async () => {
    vi.mocked(pythonClient.get).mockRejectedValueOnce(
      new Error("Cuenta corriente no encontrada para este proveedor"),
    )

    const { result } = renderHook(() => useSupplierAccount("sup-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.isError).toBe(false)
    expect(result.current.data).toBeNull()
  })

  it("TRIANGULATE: la cuenta existente se mapea igual que siempre", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(ACCOUNT_API)

    const { result } = renderHook(() => useSupplierAccount("sup-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.data).toBeDefined())

    expect(result.current.data?.balance).toBe(116550)
    expect(result.current.data?.supplierId).toBe("sup-1")
  })

  it("TRIANGULATE: un error real (no el 404 de cuenta) sigue siendo error", async () => {
    vi.mocked(pythonClient.get).mockRejectedValueOnce(
      new Error("Error interno de base de datos."),
    )

    const { result } = renderHook(() => useSupplierAccount("sup-1"), {
      wrapper: makeWrapper(),
    })

    await waitFor(() => expect(result.current.isError).toBe(true))

    expect(result.current.data).toBeUndefined()
  })
})
