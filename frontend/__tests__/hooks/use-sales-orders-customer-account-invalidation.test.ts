/**
 * fix-supplier-account-ui-post-delete (bug 1, camino POS/SalesOrder): misma
 * clase de bug que usePurchases/useSales — confirmar una SalesOrder o hacer
 * un quickSale con payment_method="credit" postea un cargo en
 * customerAccounts (vía rpc_confirm_sales_order / rpc_quick_sale), pero
 * useConfirmSalesOrder/useQuickSale solo invalidaban salesOrders/sales/
 * branchStock — la cuenta corriente del cliente quedaba stale.
 *
 * Ciclo: RED → GREEN
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import {
  useConfirmSalesOrder,
  useQuickSale,
  type ConfirmOrderInput,
  type QuickSaleInput,
} from "@/hooks/data/use-sales-orders"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:  vi.fn(),
    post: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

function makeWrapperWithClient() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

const invalidatesCustomerAccounts = (spy: ReturnType<typeof vi.spyOn>) =>
  spy.mock.calls.some((c: unknown[]) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0] === "customerAccounts")

const confirmPayload: ConfirmOrderInput = {
  idempotency_key: "idem-confirm-1",
  payment_method:  "credit",
}

function quickSalePayload(overrides: Partial<QuickSaleInput> = {}): QuickSaleInput {
  return {
    idempotency_key: "idem-quick-1",
    items: [{ product_id: "prod-1", quantity: 1, price: 100, subtotal: 100 }],
    payment_method:  "credit",
    client_id:       "client-1",
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(pythonClient.post).mockResolvedValue({
    sales_order_id: "so-1",
    operation_id:   "op-1",
    total:          100,
    fiscal_doc_id:  null,
    replayed:       false,
  })
})

describe("useConfirmSalesOrder — invalida customerAccounts (venta a crédito)", () => {
  it("confirma una orden a crédito e invalida customerAccounts", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useConfirmSalesOrder(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ salesOrderId: "so-1", payload: confirmPayload })
    })

    expect(invalidatesCustomerAccounts(spy)).toBe(true)
  })
})

describe("useQuickSale — invalida customerAccounts (venta a crédito)", () => {
  it("quickSale a crédito invalida customerAccounts", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useQuickSale(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(quickSalePayload())
    })

    expect(invalidatesCustomerAccounts(spy)).toBe(true)
  })
})
