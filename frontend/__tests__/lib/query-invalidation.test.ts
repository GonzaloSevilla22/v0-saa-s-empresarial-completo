/**
 * presupuestos-modulo (D12, task 4.5) — `invalidateAfterSale`: la UNIÓN de lo que
 * toca una venta confirmada, en un solo lugar.
 *
 * Hallazgo que cierra: `useConfirmSalesOrder` y `useQuickSale` (POS) repetían una
 * lista que no incluía caja, banco ni productos — después de vender, `/caja`,
 * `/banco` y el stock del catálogo quedaban desactualizados hasta recargar.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { invalidateAfterSale, SALE_INVALIDATED_ROOTS } from "@/lib/query-invalidation"
import { useConfirmSalesOrder, useQuickSale } from "@/hooks/data/use-sales-orders"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn() },
}))
import { pythonClient } from "@/lib/api/python-client"

function rootsInvalidated(spy: ReturnType<typeof vi.spyOn>): string[] {
  return spy.mock.calls.map((c: unknown[]) => String((c[0] as { queryKey?: unknown[] })?.queryKey?.[0]))
}

const EXPECTED = [
  "salesOrders",
  "sales",
  "branchStock",
  "products",
  "customerAccounts",
  "receivables",
  "cashSessions",
  "cashMovements",
  "bankAccounts",
]

describe("invalidateAfterSale", () => {
  it("invalida las nueve raíces que toca una venta", () => {
    const queryClient = new QueryClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterSale(queryClient)
    expect(rootsInvalidated(spy).sort()).toEqual([...EXPECTED].sort())
  })

  it.each(EXPECTED)("incluye %s", (root) => {
    const queryClient = new QueryClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterSale(queryClient)
    expect(rootsInvalidated(spy)).toContain(root)
  })

  it("la lista exportada es la misma que se invalida (un test no puede quedar atrás del código)", () => {
    expect([...SALE_INVALIDATED_ROOTS].sort()).toEqual([...EXPECTED].sort())
  })

  it("invalida de verdad una consulta cacheada (no sólo llama al método)", async () => {
    const queryClient = new QueryClient()
    const fetcher = vi.fn().mockResolvedValue([])
    await queryClient.fetchQuery({ queryKey: ["cashSessions", "current", "cb-1"], queryFn: fetcher })
    expect(queryClient.getQueryState(["cashSessions", "current", "cb-1"])?.isInvalidated).toBe(false)

    invalidateAfterSale(queryClient)

    expect(queryClient.getQueryState(["cashSessions", "current", "cb-1"])?.isInvalidated).toBe(true)
  })
})

describe("las mutaciones de venta usan la unión", () => {
  function setup() {
    const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const wrapper = ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children)
    return { queryClient, wrapper }
  }

  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(pythonClient.post).mockResolvedValue({
      sales_order_id: "so-1",
      operation_id: "op-1",
      total: 100,
      fiscal_doc_id: null,
      replayed: false,
    })
  })

  it("useQuickSale (POS) ahora también invalida caja, banco y productos", async () => {
    const { queryClient, wrapper } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useQuickSale(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        idempotency_key: "k1",
        items: [{ product_id: "p1", quantity: 1, price: 100, subtotal: 100 }],
        payment_method: "cash",
      })
    })

    const roots = rootsInvalidated(spy)
    for (const root of EXPECTED) expect(roots).toContain(root)
  })

  it("useConfirmSalesOrder ahora también invalida caja, banco y productos, y el detalle de la orden confirmada", async () => {
    const { queryClient, wrapper } = setup()
    await queryClient.fetchQuery({ queryKey: ["salesOrders", "detail", "so-9"], queryFn: async () => ({}) })
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useConfirmSalesOrder(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ salesOrderId: "so-9", payload: { idempotency_key: "k2", payment_method: "cash" } })
    })

    const roots = rootsInvalidated(spy)
    for (const root of EXPECTED) expect(roots).toContain(root)
    expect(queryClient.getQueryState(["salesOrders", "detail", "so-9"])?.isInvalidated).toBe(true)
  })
})
