/**
 * presupuestos-modulo (tanda B, 6.10) — `useSales` mapea el origen presupuesto
 * de la venta (`source_quote_id`, `source_quote_number`) y `has_service_lines`
 * (derivados de lectura del servidor) al modelo de la venta.
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

describe("useSales — origen presupuesto y líneas de servicio", () => {
  beforeEach(() => vi.clearAllMocks())

  it("una venta nacida de un presupuesto trae su id y su número", async () => {
    const [sale] = await loadSales([{ ...base, source_quote_id: "q-9", source_quote_number: 12 }])
    expect(sale.sourceQuoteId).toBe("q-9")
    expect(sale.sourceQuoteNumber).toBe(12)
  })

  it("una venta suelta no tiene origen (null, no undefined) ni líneas de servicio", async () => {
    const [sale] = await loadSales([base])
    expect(sale.sourceQuoteId).toBeNull()
    expect(sale.sourceQuoteNumber).toBeNull()
    expect(sale.hasServiceLines).toBe(false)
  })

  it("has_service_lines llega como hasServiceLines", async () => {
    const [sale] = await loadSales([{ ...base, has_service_lines: true }])
    expect(sale.hasServiceLines).toBe(true)
  })
})
