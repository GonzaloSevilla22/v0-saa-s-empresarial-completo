/**
 * useQuickSale — el error de stock insuficiente llega SIN aplanar (candidato
 * "POS sin wirear a operation-errors", origen sucursal-guard-vaciado-
 * auditoria G3).
 *
 * Antes de este fix, `translateSalesOrderError` aplanaba cualquier mensaje
 * que contuviera "stock_insuficiente" a un genérico sin uuid ANTES de que
 * la página lo viera — así que `humanizeOperationError` (lib/operation-
 * errors) nunca tenía la oportunidad de nombrar el producto ni ofrecer la
 * acción "Transferir stock" en /ventas/pos, aunque el helper ya supiera
 * reconocer el formato. La humanización vive en un solo lugar (el
 * consumidor, vía humanizeOperationError) — este hook ya no la duplica ni
 * la destruye.
 *
 * Ciclo: RED → GREEN. Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useQuickSale, useConfirmSalesOrder, type QuickSaleInput } from "@/hooks/data/use-sales-orders"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:  vi.fn(),
    post: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const PRODUCT_ID = "0dd2e5bb-2b93-4470-b4b6-52f008046112"

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

function basePayload(overrides: Partial<QuickSaleInput> = {}): QuickSaleInput {
  return {
    idempotency_key: "idem-1",
    items: [{ product_id: PRODUCT_ID, quantity: 1, price: 100, subtotal: 100 }],
    payment_method: "other",
    ...overrides,
  }
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("useQuickSale — error de stock sin aplanar", () => {
  it("propaga el uuid del producto para que la página lo humanice", async () => {
    ;(pythonClient.post as ReturnType<typeof vi.fn>).mockRejectedValue(
      new Error(`stock_insuficiente para producto ${PRODUCT_ID}: disponible 0, solicitado 3`),
    )

    const { result } = renderHook(() => useQuickSale(), { wrapper: makeWrapper() })

    let caught: Error | undefined
    await act(async () => {
      try {
        await result.current.mutateAsync(basePayload())
      } catch (err) {
        caught = err as Error
      }
    })

    expect(caught?.message).toContain(PRODUCT_ID)
    // nunca el genérico previo — humanizeOperationError es quien decide el
    // texto final, no este hook.
    expect(caught?.message).not.toBe("Stock insuficiente para completar la venta.")
  })

  it("otros errores conocidos siguen traduciéndose acá (no se tocan)", async () => {
    ;(pythonClient.post as ReturnType<typeof vi.fn>).mockRejectedValue(new Error("no_open_session"))

    const { result } = renderHook(() => useQuickSale(), { wrapper: makeWrapper() })

    let caught: Error | undefined
    await act(async () => {
      try {
        await result.current.mutateAsync(basePayload())
      } catch (err) {
        caught = err as Error
      }
    })

    expect(caught?.message).toBe(
      "No hay sesión de caja abierta. Abrí una sesión antes de cobrar en efectivo.",
    )
  })
})

describe("useConfirmSalesOrder — mismo passthrough (comparte translateSalesOrderError)", () => {
  it("propaga el uuid del producto sin aplanar", async () => {
    ;(pythonClient.post as ReturnType<typeof vi.fn>).mockRejectedValue(
      new Error(`stock_insuficiente para producto ${PRODUCT_ID}: disponible 0, solicitado 1`),
    )

    const { result } = renderHook(() => useConfirmSalesOrder(), { wrapper: makeWrapper() })

    let caught: Error | undefined
    await act(async () => {
      try {
        await result.current.mutateAsync({
          salesOrderId: "so-1",
          payload: { idempotency_key: "idem-2", payment_method: "cash" },
        })
      } catch (err) {
        caught = err as Error
      }
    })

    expect(caught?.message).toContain(PRODUCT_ID)
  })
})
