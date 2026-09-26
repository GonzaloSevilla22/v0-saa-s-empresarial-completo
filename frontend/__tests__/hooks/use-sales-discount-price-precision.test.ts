/**
 * useSales — el precio con descuento viaja sin ruido binario
 * (ventas-unidades-conversion, cuarta revisión del PR #584, D-F′).
 *
 * D-F′: el precio de una línea se guarda con su precisión real
 * (`sales.amount` / `sales.total` son numeric sin escala) y `roundUnitPrice`
 * sólo limpia el ruido binario del float. El monto con descuento del
 * formulario de venta se mandaba crudo: 4,575 al 10 % viajaba como
 * 4.117500000000001 y quedaba grabado para siempre (total 411.7500000000001).
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
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

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

function cartItem(unitPrice: number, discount: number, quantity = 100) {
  return {
    id: "cart-1",
    productId: "prod-1",
    productName: "Jamón",
    unitPrice,
    quantity,
    discount,
    subtotal: unitPrice * quantity * (1 - discount / 100),
    unitId: "unit-g",
  }
}

type Body = { items: Array<{ amount: number }> }

const postedAmount = () => {
  const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0] as [string, Body]
  return body.items[0].amount
}
const putAmount = () => {
  const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0] as [string, Body]
  return body.items[0].amount
}

async function add(unitPrice: number, discount: number) {
  const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
  await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
  await act(async () => {
    await result.current.addSaleOperation({
      items: [cartItem(unitPrice, discount)],
      meta: {
        idempotencyKey: "key-df",
        clientId: null,
        date: "2026-09-25",
        currency: "ARS",
        branchId: null,
        orgId: "acc-1",
      },
    })
  })
}

async function update(unitPrice: number, discount: number) {
  const { result } = renderHook(() => useSales(), { wrapper: makeWrapper() })
  await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
  await act(async () => {
    await result.current.updateSaleOperation({
      saleIds: ["sale-1"],
      newItems: [cartItem(unitPrice, discount)],
      meta: { clientId: null, date: "2026-09-25", currency: "ARS", orgId: "acc-1" },
    })
  })
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
    items: [], total: 0, page: 0, pages: 0,
  })
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({ operation_id: "op-1" })
  ;(pythonClient.put as ReturnType<typeof vi.fn>).mockResolvedValue({ operation_id: "op-2" })
})

describe("useSales — precio con descuento sin ruido binario (D-F′)", () => {
  it("alta: $4,575/g al 10 % viaja como 4.1175 exacto (no 4.117500000000001)", async () => {
    await add(4.575, 10)
    expect(postedAmount()).toBe(4.1175)
  })

  it("edición: $4,575/g al 10 % viaja como 4.1175 exacto", async () => {
    await update(4.575, 10)
    expect(putAmount()).toBe(4.1175)
  })

  it("triangulación: $2,20 al 10 % es 1.98 (no 1.9800000000000002) en alta y en edición", async () => {
    await add(2.2, 10)
    expect(postedAmount()).toBe(1.98)
    await update(2.2, 10)
    expect(putAmount()).toBe(1.98)
  })

  it("sin descuento el precio de la línea viaja tal cual, con toda su precisión", async () => {
    await add(1.23456, 0)
    expect(postedAmount()).toBe(1.23456)
  })
})
