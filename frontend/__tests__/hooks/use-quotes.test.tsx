/**
 * presupuestos-modulo (D12, task 4.6) — `hooks/data/use-quotes.ts` reescrito
 * sobre el contrato nuevo: listado paginado con filtros, detalle, alta,
 * edición (reemplazo completo con `revision`), transición, borrado, validez por
 * defecto y PDF. Sin `useAcceptQuote`: el endpoint `/accept` se retira.
 *
 * Mock: `@/lib/api/python-client`, `@/lib/api/document-pdf`, `useAuth`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/lib/api/document-pdf", () => ({ fetchDocumentPdf: vi.fn() }))
vi.mock("@/contexts/auth-context", () => ({
  useAuth: () => ({ user: { accountId: "acc-1" } }),
}))

import { pythonClient } from "@/lib/api/python-client"
import { fetchDocumentPdf } from "@/lib/api/document-pdf"
import { PythonApiError } from "@/lib/api/python-api-error"
import * as quotesModule from "@/hooks/data/use-quotes"
import {
  fetchQuotePdf,
  useConvertQuote,
  useCreateQuote,
  useDeleteQuote,
  useQuote,
  useQuoteSettings,
  useQuotes,
  useTransitionQuote,
  useUpdateQuote,
  useUpdateQuoteSettings,
} from "@/hooks/data/use-quotes"
import type { CreateQuoteInput, QuoteConvertInput, UpdateQuoteInput } from "@/lib/quote-types"

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { queryClient, wrapper }
}

const PAGE = { items: [], total: 0, page: 1, pages: 0 }

const createPayload: CreateQuoteInput = {
  client_id: "c-1",
  valid_until: "2026-10-30",
  notes: "Entrega en 48 hs",
  items: [{ product_id: "p-1", unit_id: null, quantity: 2, price: 500, subtotal: 1000 }],
}

const updatePayload: UpdateQuoteInput = {
  client_id: "c-1",
  branch_id: null,
  valid_until: "2026-11-15",
  notes: null,
  revision: 3,
  items: [{ product_id: null, unit_id: null, quantity: 1, price: 800, subtotal: 800, description: "Flete" }],
}

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(pythonClient.get).mockResolvedValue(PAGE)
  vi.mocked(pythonClient.post).mockResolvedValue({ id: "q-1" })
  vi.mocked(pythonClient.put).mockResolvedValue({ id: "q-1" })
  vi.mocked(pythonClient.patch).mockResolvedValue({ default_quote_validity_days: 30 })
  vi.mocked(pythonClient.delete).mockResolvedValue(undefined)
})

describe("contrato del módulo", () => {
  it("no exporta useAcceptQuote (el endpoint /accept se retiró)", () => {
    expect("useAcceptQuote" in quotesModule).toBe(false)
  })
})

describe("useQuotes — listado paginado", () => {
  it("sin filtros pide /quotes pelado", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useQuotes(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/quotes")
  })

  it("serializa los filtros con los nombres del backend, en orden estable", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(
      () => useQuotes({ status: "sent", clientId: "c-1", q: "P-12", page: 2, pageSize: 5 }),
      { wrapper },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/quotes?status=sent&client_id=c-1&q=P-12&page=2&page_size=5")
  })

  it("omite el texto de búsqueda vacío o en blanco y recorta el que sí hay", async () => {
    const { wrapper } = setup()
    const blank = renderHook(() => useQuotes({ q: "   ", status: "draft" }), { wrapper })
    await waitFor(() => expect(blank.result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenLastCalledWith("/quotes?status=draft")

    const trimmed = renderHook(() => useQuotes({ q: "  Ana  " }), { wrapper })
    await waitFor(() => expect(trimmed.result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenLastCalledWith("/quotes?q=Ana")
  })

  it("filtros distintos son consultas distintas en el caché", async () => {
    const { queryClient, wrapper } = setup()
    const a = renderHook(() => useQuotes({ status: "draft" }), { wrapper })
    const b = renderHook(() => useQuotes({ status: "sent" }), { wrapper })
    await waitFor(() => expect(a.result.current.isSuccess && b.result.current.isSuccess).toBe(true))
    expect(queryClient.getQueryCache().findAll({ queryKey: ["quotes", "list"] })).toHaveLength(2)
  })
})

describe("useQuote — detalle", () => {
  it("pide /quotes/{id}", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useQuote("q-9"), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/quotes/q-9")
  })

  it("sin id no consulta nada", () => {
    const { wrapper } = setup()
    renderHook(() => useQuote(null), { wrapper })
    expect(pythonClient.get).not.toHaveBeenCalled()
  })
})

describe("mutaciones — payload e invalidaciones", () => {
  async function cachedState(queryClient: QueryClient) {
    await queryClient.fetchQuery({ queryKey: ["quotes", "list", {}], queryFn: async () => PAGE })
    await queryClient.fetchQuery({ queryKey: ["quotes", "detail", "q-1"], queryFn: async () => ({}) })
  }
  const invalidated = (queryClient: QueryClient, key: unknown[]) =>
    queryClient.getQueryState(key)?.isInvalidated

  it("useCreateQuote manda el payload a POST /quotes e invalida listas y detalle", async () => {
    const { queryClient, wrapper } = setup()
    await cachedState(queryClient)
    const { result } = renderHook(() => useCreateQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/quotes", createPayload)
    expect(invalidated(queryClient, ["quotes", "list", {}])).toBe(true)
    expect(invalidated(queryClient, ["quotes", "detail", "q-1"])).toBe(true)
  })

  it("useUpdateQuote hace PUT /quotes/{id} con el reemplazo completo (incluida la revision) e invalida", async () => {
    const { queryClient, wrapper } = setup()
    await cachedState(queryClient)
    const { result } = renderHook(() => useUpdateQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ quoteId: "q-1", payload: updatePayload })
    })

    expect(pythonClient.put).toHaveBeenCalledWith("/quotes/q-1", updatePayload)
    expect(invalidated(queryClient, ["quotes", "list", {}])).toBe(true)
    expect(invalidated(queryClient, ["quotes", "detail", "q-1"])).toBe(true)
  })

  it.each([
    ["send", undefined, { action: "send" }],
    ["reject", "El cliente no respondió", { action: "reject", reason: "El cliente no respondió" }],
  ] as const)("useTransitionQuote(%s) hace POST /quotes/{id}/transition", async (action, reason, body) => {
    const { queryClient, wrapper } = setup()
    await cachedState(queryClient)
    const { result } = renderHook(() => useTransitionQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ quoteId: "q-1", action, reason })
    })

    expect(pythonClient.post).toHaveBeenCalledWith("/quotes/q-1/transition", body)
    expect(invalidated(queryClient, ["quotes", "detail", "q-1"])).toBe(true)
    expect(invalidated(queryClient, ["quotes", "list", {}])).toBe(true)
  })

  it("useTransitionQuote no manda 'reason' cuando no hay motivo (la clave viaja ausente)", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useTransitionQuote(), { wrapper })
    await act(async () => {
      await result.current.mutateAsync({ quoteId: "q-1", action: "send", reason: "   " })
    })
    expect(vi.mocked(pythonClient.post).mock.calls[0][1]).toEqual({ action: "send" })
  })

  it("useDeleteQuote hace DELETE, invalida las listas y descarta el detalle borrado", async () => {
    const { queryClient, wrapper } = setup()
    await cachedState(queryClient)
    const { result } = renderHook(() => useDeleteQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync("q-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/quotes/q-1")
    expect(invalidated(queryClient, ["quotes", "list", {}])).toBe(true)
    // El detalle de un presupuesto que ya no existe no se vuelve a pedir.
    expect(queryClient.getQueryState(["quotes", "detail", "q-1"])).toBeUndefined()
  })

  it("el error del servidor llega con su code estable (no se traduce en el hook)", async () => {
    vi.mocked(pythonClient.put).mockRejectedValue(
      new PythonApiError("El presupuesto cambió", 409, { code: "quote_changed" }),
    )
    const { wrapper } = setup()
    const { result } = renderHook(() => useUpdateQuote(), { wrapper })

    const err = await act(async () =>
      result.current.mutateAsync({ quoteId: "q-1", payload: updatePayload }).catch((e: unknown) => e),
    )

    expect(err).toBeInstanceOf(PythonApiError)
    expect((err as PythonApiError).code).toBe("quote_changed")
  })

  it("una mutación fallida NO invalida nada", async () => {
    vi.mocked(pythonClient.post).mockRejectedValue(new PythonApiError("x", 403, { code: "insufficient_role" }))
    const { queryClient, wrapper } = setup()
    await cachedState(queryClient)
    const { result } = renderHook(() => useCreateQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload).catch(() => undefined)
    })

    expect(invalidated(queryClient, ["quotes", "list", {}])).toBe(false)
  })
})

describe("validez por defecto", () => {
  it("useQuoteSettings lee GET /settings/quotes y lo expone en camelCase", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({ default_quote_validity_days: 15 })
    const { wrapper } = setup()
    const { result } = renderHook(() => useQuoteSettings(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/settings/quotes")
    expect(result.current.data).toEqual({ defaultQuoteValidityDays: 15 })
  })

  it("useUpdateQuoteSettings hace PATCH con los días y devuelve lo guardado", async () => {
    const { queryClient, wrapper } = setup()
    await queryClient.fetchQuery({ queryKey: ["quote-settings", "acc-1"], queryFn: async () => ({ defaultQuoteValidityDays: 15 }) })
    const { result } = renderHook(() => useUpdateQuoteSettings(), { wrapper })

    let saved: unknown
    await act(async () => {
      saved = await result.current.mutateAsync(30)
    })

    expect(pythonClient.patch).toHaveBeenCalledWith("/settings/quotes", { default_quote_validity_days: 30 })
    expect(saved).toEqual({ defaultQuoteValidityDays: 30 })
    expect(queryClient.getQueryState(["quote-settings", "acc-1"])?.isInvalidated).toBe(true)
  })
})

describe("fetchQuotePdf", () => {
  it("delega en fetchDocumentPdf con la ruta del presupuesto y la disposición", async () => {
    const blob = new Blob(["%PDF"], { type: "application/pdf" })
    vi.mocked(fetchDocumentPdf).mockResolvedValue(blob)

    await expect(fetchQuotePdf("q-1", "attachment")).resolves.toBe(blob)
    expect(fetchDocumentPdf).toHaveBeenCalledWith("/quotes/q-1/pdf", { disposition: "attachment" })
  })

  it("la disposición por defecto es inline y el id se escapa", async () => {
    vi.mocked(fetchDocumentPdf).mockResolvedValue(null)
    await expect(fetchQuotePdf("a/b")).resolves.toBeNull()
    expect(fetchDocumentPdf).toHaveBeenCalledWith("/quotes/a%2Fb/pdf", { disposition: "inline" })
  })
})


// ── Conversión en venta (tanda B, 6.7) ────────────────────────────────────────

describe("useConvertQuote — conversión atómica a venta", () => {
  const convertPayload: QuoteConvertInput = {
    expected_revision: 3,
    payment_method_id: "pm-1",
    branch_id: "b-1",
    cash_session_id: "cs-1",
    bank_account_id: null,
    canal: null,
  }
  const converted = {
    quote_id: "q-1",
    quote_number: 12,
    quote_number_label: "P-00000012",
    sales_order_id: "so-1",
    operation_id: "op-1",
    total: "3000.00",
    replayed: false,
  }

  beforeEach(() => {
    vi.mocked(pythonClient.post).mockResolvedValue(converted)
  })

  it("hace POST /quotes/{id}/convert con la clave por HEADER y sin repetirla en el cuerpo", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useConvertQuote(), { wrapper })

    let out: unknown
    await act(async () => {
      out = await result.current.mutateAsync({ quoteId: "q-1", payload: convertPayload, idempotencyKey: "key-A" })
    })

    expect(out).toEqual(converted)
    expect(pythonClient.post).toHaveBeenCalledTimes(1)
    const [path, body, headers] = vi.mocked(pythonClient.post).mock.calls[0]
    expect(path).toBe("/quotes/q-1/convert")
    expect(headers).toEqual({ "Idempotency-Key": "key-A" })
    expect(body).toEqual(convertPayload)
    expect(body).not.toHaveProperty("idempotency_key")
  })

  it("la clave de otro presupuesto viaja en su propia request (A perdido, luego B: sin mezclar)", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useConvertQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ quoteId: "q-A", payload: convertPayload, idempotencyKey: "key-A" })
      await result.current.mutateAsync({ quoteId: "q-B", payload: convertPayload, idempotencyKey: "key-B" })
    })

    const calls = vi.mocked(pythonClient.post).mock.calls
    expect(calls.map((c) => [c[0], (c[2] as Record<string, string>)["Idempotency-Key"]])).toEqual([
      ["/quotes/q-A/convert", "key-A"],
      ["/quotes/q-B/convert", "key-B"],
    ])
  })

  it("al éxito invalida quotes.* y todo lo que toca una venta (invalidateAfterSale)", async () => {
    const { queryClient, wrapper } = setup()
    const keys: unknown[][] = [
      ["quotes", "list", {}],
      ["quotes", "detail", "q-1"],
      ["salesOrders", "list"],
      ["sales", "list"],
      ["branchStock", "branch", "b-1"],
      ["products", "list"],
      ["customerAccounts", "client", "c-1"],
      ["receivables", "list"],
      ["cashSessions", "current", "cb-1"],
      ["cashMovements", "list"],
      ["bankAccounts", "list"],
    ]
    for (const key of keys) await queryClient.fetchQuery({ queryKey: key, queryFn: async () => ({}) })
    const { result } = renderHook(() => useConvertQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ quoteId: "q-1", payload: convertPayload, idempotencyKey: "key-A" })
    })

    for (const key of keys) {
      expect(queryClient.getQueryState(key)?.isInvalidated, JSON.stringify(key)).toBe(true)
    }
  })

  it("el replay (replayed: true) también invalida: la venta ya existe y las pantallas deben verla", async () => {
    vi.mocked(pythonClient.post).mockResolvedValue({ ...converted, replayed: true })
    const { queryClient, wrapper } = setup()
    await queryClient.fetchQuery({ queryKey: ["quotes", "detail", "q-1"], queryFn: async () => ({}) })
    const { result } = renderHook(() => useConvertQuote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ quoteId: "q-1", payload: convertPayload, idempotencyKey: "key-A" })
    })

    expect(queryClient.getQueryState(["quotes", "detail", "q-1"])?.isInvalidated).toBe(true)
  })

  it("un fallo llega con su code estable y NO invalida nada", async () => {
    vi.mocked(pythonClient.post).mockRejectedValue(
      new PythonApiError("stock_insuficiente para producto p-1", 409, { code: "stock_insuficiente" }),
    )
    const { queryClient, wrapper } = setup()
    await queryClient.fetchQuery({ queryKey: ["quotes", "detail", "q-1"], queryFn: async () => ({}) })
    await queryClient.fetchQuery({ queryKey: ["products", "list"], queryFn: async () => ({}) })
    const { result } = renderHook(() => useConvertQuote(), { wrapper })

    const err = await act(async () =>
      result.current
        .mutateAsync({ quoteId: "q-1", payload: convertPayload, idempotencyKey: "key-A" })
        .catch((e: unknown) => e),
    )

    expect(err).toBeInstanceOf(PythonApiError)
    expect((err as PythonApiError).code).toBe("stock_insuficiente")
    expect(queryClient.getQueryState(["quotes", "detail", "q-1"])?.isInvalidated).toBe(false)
    expect(queryClient.getQueryState(["products", "list"])?.isInvalidated).toBe(false)
  })
})
