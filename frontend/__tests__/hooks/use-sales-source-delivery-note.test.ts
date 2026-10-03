/**
 * remitos-venta (tanda B, 7.6, D13) — `useSales` mapea el remito de origen de la
 * venta (`source_delivery_note_id`, `source_delivery_note_number`) y el motivo de
 * no edición (`edit_locked_reason`), derivados de lectura del servidor, al modelo
 * de la venta.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useSales } from "@/hooks/data/use-sales"

function wrapper({ children }: { children: React.ReactNode }) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return React.createElement(QueryClientProvider, { client }, children)
}

const base = {
  id: "sale-1",
  date: "2026-10-02",
  product_id: "prod-1",
  product_name: "Remera",
  client_id: null,
  quantity: 1,
  amount: "1500",
  total: "1500",
  currency: "ARS",
  operation_id: "op-1",
}

async function loadSales(rows: Array<Record<string, unknown>>) {
  vi.mocked(pythonClient.get).mockResolvedValueOnce({ items: rows, total: rows.length })
  const { result } = renderHook(() => useSales(), { wrapper })
  await waitFor(() => expect(result.current.isLoading).toBe(false))
  return result.current.sales
}

describe("useSales — origen remito y motivo de no edición", () => {
  beforeEach(() => vi.clearAllMocks())

  it("una venta nacida de un remito trae su id, su número y el motivo de no edición", async () => {
    const [sale] = await loadSales([
      {
        ...base,
        source_delivery_note_id: "dn-3",
        source_delivery_note_number: 7,
        edit_locked_reason: "delivery_note_sale_locked",
      },
    ])
    expect(sale.sourceDeliveryNoteId).toBe("dn-3")
    expect(sale.sourceDeliveryNoteNumber).toBe(7)
    expect(sale.editLockedReason).toBe("delivery_note_sale_locked")
  })

  it("una venta suelta no tiene origen remito ni motivo (null, no undefined)", async () => {
    const [sale] = await loadSales([base])
    expect(sale.sourceDeliveryNoteId).toBeNull()
    expect(sale.sourceDeliveryNoteNumber).toBeNull()
    expect(sale.editLockedReason).toBeNull()
  })

  it("el origen remito no pisa al origen presupuesto: son independientes", async () => {
    const [sale] = await loadSales([{ ...base, source_quote_id: "q-9", source_quote_number: 12 }])
    expect(sale.sourceQuoteId).toBe("q-9")
    expect(sale.sourceDeliveryNoteId).toBeNull()
  })
})
