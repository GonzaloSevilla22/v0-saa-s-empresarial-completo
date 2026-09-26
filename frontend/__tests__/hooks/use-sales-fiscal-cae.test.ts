/**
 * factura-fiscal-imprimible (task 6.1) — `useSales` mapea el CAE, su
 * vencimiento y el tipo de comprobante al `SaleFiscalState` de la venta.
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

const row = {
  id: "sale-1",
  date: "2026-09-21",
  product_id: "prod-1",
  product_name: "Ciclista Lycra",
  client_id: null,
  quantity: 1,
  amount: "32500",
  total: "32500",
  currency: "ARS",
  operation_id: "op-1",
  fiscal_document_id: "fd-1",
  fiscal_document_status: "authorized",
  fiscal_punto_de_venta: 3,
  fiscal_number: 501,
  fiscal_cae: "71234567890123",
  fiscal_cae_due_date: "2026-10-05",
  fiscal_comprobante_type: "factura_c",
}

describe("useSales — CAE del comprobante", () => {
  beforeEach(() => vi.clearAllMocks())

  it("el estado fiscal trae CAE, vencimiento y tipo", async () => {
    vi.mocked(pythonClient.get).mockResolvedValueOnce({ items: [row], total: 1 })

    const { result } = renderHook(() => useSales(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.sales[0].fiscal).toMatchObject({
      documentId: "fd-1",
      status: "authorized",
      label: "0003-00000501",
      cae: "71234567890123",
      caeDueDate: "2026-10-05",
      comprobanteType: "factura_c",
    })
  })
})
