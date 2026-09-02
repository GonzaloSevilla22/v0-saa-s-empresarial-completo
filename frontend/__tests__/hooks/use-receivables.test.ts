/**
 * cobranzas-panel (tasks 4.4 / 4.5): useReceivables + useReceivablesSummary
 * y la regresión de D8 — TODA mutación que altera un saldo de cuenta
 * corriente invalida también las claves de `receivables`, EN EL HOOK y no en
 * la pantalla (lección registrada: "invalidar cuentas corrientes en TODAS
 * las mutaciones que postean cargos").
 *
 * Mocks: @/lib/api/python-client + @/contexts/auth-context.
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
    delete: vi.fn(),
  },
}))

vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { id: "user-1", accountId: "acc-1" } }),
}))

import { pythonClient } from "@/lib/api/python-client"
import { useReceivables, useReceivablesSummary } from "@/hooks/data/use-receivables"
import {
  useRegisterPayment,
  useReversePaymentReceived,
} from "@/hooks/data/use-customer-account"
import { useConfirmSalesOrder, useQuickSale } from "@/hooks/data/use-sales-orders"
import { useSales } from "@/hooks/data/use-sales"

const RAW_PAGE = {
  items: [
    {
      client_id: "11111111-1111-1111-1111-111111111111",
      client_name: "Deudor Grande",
      balance: "12500.50",
      days_since_last_charge: 12,
      days_since_last_payment: null,
      last_payment_date: null,
    },
  ],
  total: 1,
  page: 0,
  pages: 1,
}

function makeWrapperAndClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

const invalidatesReceivables = (spy: ReturnType<typeof vi.spyOn>) =>
  spy.mock.calls.some(
    (c: unknown[]) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0] === "receivables",
  )

beforeEach(() => vi.clearAllMocks())

// ── 4.4: hooks de lectura ─────────────────────────────────────────────────────

describe("useReceivables", () => {
  it("consulta GET /reports/receivables con paginación y orden, y mapea al dominio", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce(RAW_PAGE)
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(
      () => useReceivables({ page: 0, size: 25, sort: "balance", sortDir: "desc" }),
      { wrapper },
    )

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(pythonClient.get).toHaveBeenCalledWith(
      "/reports/receivables?page=0&size=25&sort=balance&sort_dir=desc",
    )
    expect(result.current.data?.total).toBe(1)
    const row = result.current.data?.items[0]
    expect(row?.clientName).toBe("Deudor Grande")
    expect(row?.balance).toBe(12500.5)
    // D4/OQ-4: la ausencia viaja como null hasta la superficie.
    expect(row?.daysSinceLastPayment).toBeNull()
  })

  it("traduce sort/sortDir no-default a la query string", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({ ...RAW_PAGE, items: [], total: 0, pages: 0 })
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(
      () =>
        useReceivables({
          page: 2,
          size: 10,
          sort: "days_since_last_charge",
          sortDir: "asc",
        }),
      { wrapper },
    )

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(pythonClient.get).toHaveBeenCalledWith(
      "/reports/receivables?page=2&size=10&sort=days_since_last_charge&sort_dir=asc",
    )
  })
})

describe("useReceivablesSummary", () => {
  it("consulta GET /reports/receivables/summary y mapea al dominio", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({
      total_receivable: "567000.00",
      debtor_count: 11,
    })
    const { wrapper } = makeWrapperAndClient()

    const { result } = renderHook(() => useReceivablesSummary(), { wrapper })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(pythonClient.get).toHaveBeenCalledWith("/reports/receivables/summary")
    expect(result.current.data?.totalReceivable).toBe(567000)
    expect(result.current.data?.debtorCount).toBe(11)
  })
})

// ── 4.5 RED: regresión D8 — la invalidación vive en el hook ──────────────────

describe("D8 — registrar/anular un cobro invalida las claves de receivables", () => {
  it("useRegisterPayment invalida receivables al confirmar", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      payment_id: "pay-1",
      customer_account_id: "ca-1",
      balance_after: "0",
      replayed: false,
      operation_id: null,
    })
    const { wrapper, queryClient } = makeWrapperAndClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useRegisterPayment("client-1"), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ idempotencyKey: "idem-1", amount: 100 })
    })

    expect(invalidatesReceivables(spy)).toBe(true)
  })

  it("useReversePaymentReceived invalida receivables al confirmar", async () => {
    vi.mocked(pythonClient.delete).mockResolvedValueOnce({
      payment_id: "pay-1",
      reversed: true,
      account_movement_id: "mov-1",
      cash_reversal_id: null,
      bank_reversals: 0,
    })
    const { wrapper, queryClient } = makeWrapperAndClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useReversePaymentReceived("client-1"), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ paymentId: "pay-1" })
    })

    expect(invalidatesReceivables(spy)).toBe(true)
  })
})

describe("D8 — las mutaciones que CREAN deuda a crédito invalidan receivables", () => {
  beforeEach(() => {
    vi.mocked(pythonClient.post).mockResolvedValue({
      sales_order_id: "so-1",
      operation_id: "op-1",
      total: 100,
      fiscal_doc_id: null,
      replayed: false,
    })
  })

  it("useConfirmSalesOrder (POS) invalida receivables", async () => {
    const { wrapper, queryClient } = makeWrapperAndClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useConfirmSalesOrder(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({
        salesOrderId: "so-1",
        payload: { idempotency_key: "idem-c1", payment_method: "credit" },
      })
    })

    expect(invalidatesReceivables(spy)).toBe(true)
  })

  it("addSaleOperation (formulario de venta) invalida receivables", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({ items: [], total: 0, page: 0, pages: 0 })
    const { wrapper, queryClient } = makeWrapperAndClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useSales(), { wrapper })
    await act(async () => {
      await result.current.addSaleOperation({
        items: [
          {
            id: "i1",
            productId: "prod-1",
            productName: "Producto",
            unitPrice: 100,
            quantity: 1,
            discount: 0,
            subtotal: 100,
          },
        ],
        meta: {
          idempotencyKey: "idem-s1",
          clientId: "client-1",
          date: "2026-09-02",
          currency: "ARS",
          orgId: "org-1",
          paymentMethodId: "pm-credit",
        },
      })
    })

    expect(invalidatesReceivables(spy)).toBe(true)
  })

  it("useQuickSale (mostrador) invalida receivables", async () => {
    const { wrapper, queryClient } = makeWrapperAndClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    const { result } = renderHook(() => useQuickSale(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({
        idempotency_key: "idem-q1",
        items: [{ product_id: "prod-1", quantity: 1, price: 100, subtotal: 100 }],
        payment_method: "credit",
        client_id: "client-1",
      })
    })

    expect(invalidatesReceivables(spy)).toBe(true)
  })
})
