/**
 * remitos-venta (tanda B, 7.7, D9/D11) — borrar una venta nacida de un remito
 * devuelve el remito a `issued` en la MISMA transacción (R5). Sin invalidar
 * `deliveryNotes.*`, `/remitos` mostraría "Convertido" con "Ver venta" apuntando
 * a una orden cancelada hasta recargar.
 *
 * Una sola definición (`invalidateAfterSaleDelete`) que consumen
 * `deleteSaleMutation` y `deleteSalesByOperationMutation` de `useSales`. Un
 * borrado compensa los mismos libros que una venta confirmada escribió (cuenta
 * corriente, caja, banco, stock): comparte esa unión y suma los remitos.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { invalidateAfterSaleDelete, SALE_INVALIDATED_ROOTS } from "@/lib/query-invalidation"
import { useSales } from "@/hooks/data/use-sales"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))
import { pythonClient } from "@/lib/api/python-client"

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { queryClient, wrapper }
}

const rootsOf = (spy: ReturnType<typeof vi.spyOn>): string[] =>
  spy.mock.calls.map((c: unknown[]) => String((c[0] as { queryKey?: unknown[] })?.queryKey?.[0]))

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(pythonClient.get).mockResolvedValue({ items: [], total: 0 })
  vi.mocked(pythonClient.delete).mockResolvedValue(undefined)
})

describe("invalidateAfterSaleDelete", () => {
  it("invalida los remitos además de lo que toca una venta", () => {
    const { queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterSaleDelete(queryClient)
    const roots = rootsOf(spy)
    expect(roots).toContain("deliveryNotes")
    for (const root of SALE_INVALIDATED_ROOTS) expect(roots).toContain(root)
  })

  it("invalida de verdad el detalle cacheado de un remito (la pantalla lo vuelve a pedir)", async () => {
    const { queryClient } = setup()
    await queryClient.fetchQuery({ queryKey: ["deliveryNotes", "detail", "dn-1"], queryFn: async () => ({}) })
    expect(queryClient.getQueryState(["deliveryNotes", "detail", "dn-1"])?.isInvalidated).toBe(false)

    invalidateAfterSaleDelete(queryClient)

    expect(queryClient.getQueryState(["deliveryNotes", "detail", "dn-1"])?.isInvalidated).toBe(true)
  })

  it("no invalida de más: ninguna raíz fuera de la unión de venta y los remitos", () => {
    const { queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterSaleDelete(queryClient)
    expect(new Set(rootsOf(spy))).toEqual(new Set([...SALE_INVALIDATED_ROOTS, "deliveryNotes"]))
  })
})

describe("useSales — borrar una venta invalida los remitos", () => {
  it("deleteSale (una fila) invalida deliveryNotes", async () => {
    const { wrapper, queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useSales(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deleteSale("sale-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/sales/sale-1")
    expect(rootsOf(spy)).toContain("deliveryNotes")
  })

  it("deleteSalesByOperation (la operación entera) invalida deliveryNotes", async () => {
    const { wrapper, queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useSales(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    await act(async () => {
      await result.current.deleteSalesByOperation("op-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/sales?operation_id=op-1")
    expect(rootsOf(spy)).toContain("deliveryNotes")
  })

  it("un borrado que falla NO invalida nada (el remito sigue convertido)", async () => {
    const { wrapper, queryClient } = setup()
    vi.mocked(pythonClient.delete).mockRejectedValueOnce(new Error("delivery_note_branch_inactive"))
    const { result } = renderHook(() => useSales(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    await act(async () => {
      await expect(result.current.deleteSale("sale-1")).rejects.toThrow()
    })

    expect(rootsOf(spy)).not.toContain("deliveryNotes")
  })
})
