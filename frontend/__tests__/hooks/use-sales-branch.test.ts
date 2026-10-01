/**
 * useSales — passthrough de branch_id en el ALTA (fix ad-hoc
 * ventas-formulario-sucursal).
 *
 * Bug medido en la exploración: el `meta` de addSaleOperation ya aceptaba
 * `branchId` en su tipo (el formulario lo entrega), pero el payload del alta
 * NUNCA lo incluía, así que la venta quedaba con `sales.branch_id = NULL` y el
 * stock/caja/banco se resolvían contra la sucursal por defecto. La EDICIÓN sí
 * lo mandaba (tri-estado): sólo el alta tenía el defecto.
 *
 * Misma convención que compras (use-purchases-cash-optin.test.ts, D3):
 * `branch_id: opMeta.branchId ?? null`.
 *
 * Mock: @/lib/api/python-client — replica el transporte real: el segundo
 * argumento de `post` es el body JSON, el tercero los headers.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useSales } from "@/hooks/data/use-sales"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const BRANCH_ID = "branch-1111"
const OTHER_BRANCH_ID = "branch-2222"

const ITEMS = [
  { id: "1", productId: "p1", productName: "X", unitPrice: 10, quantity: 1, discount: 0, subtotal: 10 },
]

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

type SaleMeta = Parameters<
  ReturnType<typeof useSales>["addSaleOperation"]
>[0]["meta"]

const BASE_META: SaleMeta = {
  idempotencyKey: "k1",
  clientId: null,
  date: "2026-10-01",
  currency: "ARS",
  orgId: "acc-1",
}

async function postSale(meta: Partial<SaleMeta>) {
  const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
  await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

  await act(async () => {
    await result.current.addSaleOperation({ items: ITEMS, meta: { ...BASE_META, ...meta } })
  })

  const [url, body, headers] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
  return { url, body: body as Record<string, unknown>, headers }
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
    items: [], total: 0, page: 0, pages: 0,
  })
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({ operation_id: "op-1" })
})

describe("useSales — passthrough de branch_id en el alta (ventas-formulario-sucursal)", () => {
  it("manda la sucursal elegida como branch_id en el body", async () => {
    const { url, body } = await postSale({ branchId: BRANCH_ID })

    expect(url).toBe("/sales")
    expect(body.branch_id).toBe(BRANCH_ID)
  })

  it("con branchId null (\"Sin sucursal (general)\") manda branch_id null, no lo omite", async () => {
    const { body } = await postSale({ branchId: null })

    expect(body).toHaveProperty("branch_id", null)
  })

  it("sin branchId en el meta (cuenta sin módulo de sucursales) manda branch_id null", async () => {
    const { body } = await postSale({})

    expect(body).toHaveProperty("branch_id", null)
  })

  it("la sucursal viaja junto al resto del contexto sin pisarlo ni desplazarlo", async () => {
    const { body, headers } = await postSale({
      branchId: OTHER_BRANCH_ID,
      canal: "instagram",
      paymentMethodId: "pm-cash",
      cashSessionId: "session-1",
      bankAccountId: "bank-1",
      dueDate: "2026-11-01",
    })

    expect(body).toMatchObject({
      branch_id: OTHER_BRANCH_ID,
      canal: "instagram",
      payment_method_id: "pm-cash",
      cash_session_id: "session-1",
      bank_account_id: "bank-1",
      due_date: "2026-11-01",
      org_id: "acc-1",
    })
    expect(headers).toEqual({ "Idempotency-Key": "k1" })
  })
})
