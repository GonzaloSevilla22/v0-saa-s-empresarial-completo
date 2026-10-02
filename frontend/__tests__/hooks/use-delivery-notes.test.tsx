/**
 * remitos-venta (D11/D13, tareas 4.1-4.2) — `hooks/data/use-delivery-notes.ts`
 * sobre el contrato de `/delivery-notes`: listado paginado con filtros, detalle,
 * emisión idempotente (clave por header, reseteada en cada éxito), edición con
 * `revision`, anulación con motivo y PDF.
 *
 * Toda mutación invalida `deliveryNotes.*` MÁS `branchStock` y `products`: el
 * remito mueve stock al emitirse, al editarse y al anularse. El panel de
 * movimientos de /stock no usa React Query (se recarga al abrirse), así que no
 * hay clave de kardex que invalidar.
 *
 * Mock: `@/lib/api/python-client`, `@/lib/api/document-pdf`.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/lib/api/document-pdf", () => ({ fetchDocumentPdf: vi.fn() }))

import { pythonClient } from "@/lib/api/python-client"
import { fetchDocumentPdf } from "@/lib/api/document-pdf"
import { PythonApiError } from "@/lib/api/python-api-error"
import {
  fetchDeliveryNotePdf,
  useCancelDeliveryNote,
  useCreateDeliveryNote,
  useDeliveryNote,
  useDeliveryNotes,
  useUpdateDeliveryNote,
} from "@/hooks/data/use-delivery-notes"
import { queryKeys } from "@/lib/query-keys"
import type {
  CreateDeliveryNoteInput,
  DeliveryNoteCancelInput,
  UpdateDeliveryNoteInput,
} from "@/lib/delivery-note-types"

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { queryClient, wrapper }
}

const PAGE = { items: [], total: 0, page: 1, pages: 0 }

const createPayload: CreateDeliveryNoteInput = {
  direction: "sale",
  client_id: "c-1",
  branch_id: "b-1",
  delivery_address: "San Martín 100, Mendoza",
  notes: null,
  items: [{ product_id: "p-1", unit_id: null, quantity: 2, price: 500, subtotal: 1000 }],
}

const updatePayload: UpdateDeliveryNoteInput = {
  client_id: "c-1",
  branch_id: "b-2",
  delivery_address: null,
  notes: "Dejar con el encargado",
  revision: 3,
  items: [{ product_id: "p-1", unit_id: "u-kg", quantity: 1.5, price: 800, subtotal: 1200 }],
}

const cancelPayload: DeliveryNoteCancelInput = { reason: "Se devolvió la mercadería", revision: 2 }

const DOMAINS = [
  ["deliveryNotes", ["deliveryNotes", "list", {}]],
  ["deliveryNotes (detalle)", ["deliveryNotes", "detail", "dn-1"]],
  ["branchStock", ["branchStock", "branch", "b-1"]],
  ["products", ["products", "list"]],
] as const

beforeEach(() => {
  vi.clearAllMocks()
  window.sessionStorage.clear()
  vi.mocked(pythonClient.get).mockResolvedValue(PAGE)
  vi.mocked(pythonClient.post).mockResolvedValue({ id: "dn-1" })
  vi.mocked(pythonClient.put).mockResolvedValue({ id: "dn-1" })
})

async function seedCaches(queryClient: QueryClient) {
  for (const [, key] of DOMAINS) {
    await queryClient.fetchQuery({ queryKey: [...key], queryFn: async () => ({}) })
  }
}
const isInvalidated = (queryClient: QueryClient, key: readonly unknown[]) =>
  queryClient.getQueryState([...key])?.isInvalidated

describe("useDeliveryNotes — listado paginado", () => {
  it("sin filtros pide /delivery-notes pelado", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useDeliveryNotes(), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/delivery-notes")
  })

  it("serializa los filtros con los nombres del backend, en orden estable", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(
      () =>
        useDeliveryNotes({
          direction: "sale",
          status: "issued",
          q: "R-12",
          clientId: "c-1",
          branchId: "b-9",
          page: 2,
          pageSize: 5,
        }),
      { wrapper },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith(
      "/delivery-notes?direction=sale&status=issued&q=R-12&client_id=c-1&branch_id=b-9&page=2&page_size=5",
    )
  })

  it("el diálogo de baja de sucursal pide los pendientes SIN direction (los dos sentidos) con page_size=1", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(
      () => useDeliveryNotes({ status: "issued", branchId: "b-9", pageSize: 1 }),
      { wrapper },
    )
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/delivery-notes?status=issued&branch_id=b-9&page_size=1")
  })

  it("omite el texto de búsqueda en blanco y recorta el que sí hay", async () => {
    const { wrapper } = setup()
    const blank = renderHook(() => useDeliveryNotes({ q: "   ", status: "canceled" }), { wrapper })
    await waitFor(() => expect(blank.result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenLastCalledWith("/delivery-notes?status=canceled")

    const trimmed = renderHook(() => useDeliveryNotes({ q: "  Ana  " }), { wrapper })
    await waitFor(() => expect(trimmed.result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenLastCalledWith("/delivery-notes?q=Ana")
  })

  it("filtros distintos son consultas distintas en el caché", async () => {
    const { queryClient, wrapper } = setup()
    const a = renderHook(() => useDeliveryNotes({ status: "issued" }), { wrapper })
    const b = renderHook(() => useDeliveryNotes({ status: "converted" }), { wrapper })
    await waitFor(() => expect(a.result.current.isSuccess && b.result.current.isSuccess).toBe(true))
    expect(queryClient.getQueryCache().findAll({ queryKey: queryKeys.deliveryNotes.lists() })).toHaveLength(2)
  })
})

describe("useDeliveryNote — detalle", () => {
  it("pide /delivery-notes/{id}", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useDeliveryNote("dn-9"), { wrapper })
    await waitFor(() => expect(result.current.isSuccess).toBe(true))
    expect(pythonClient.get).toHaveBeenCalledWith("/delivery-notes/dn-9")
  })

  it("sin id no consulta nada", () => {
    const { wrapper } = setup()
    renderHook(() => useDeliveryNote(null), { wrapper })
    expect(pythonClient.get).not.toHaveBeenCalled()
  })
})

describe("useCreateDeliveryNote — emisión idempotente", () => {
  it("hace POST /delivery-notes con la clave por HEADER y sin repetirla en el cuerpo", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useCreateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })

    expect(pythonClient.post).toHaveBeenCalledTimes(1)
    const [path, body, headers] = vi.mocked(pythonClient.post).mock.calls[0]
    expect(path).toBe("/delivery-notes")
    expect(body).toEqual(createPayload)
    expect(body).not.toHaveProperty("idempotency_key")
    expect(headers).toEqual({ "Idempotency-Key": expect.stringMatching(/^[0-9a-f-]{36}$/) })
  })

  it("un reintento tras un error manda la MISMA clave (replay en el servidor, no un duplicado)", async () => {
    vi.mocked(pythonClient.post).mockRejectedValueOnce(new Error("network")).mockResolvedValueOnce({ id: "dn-1" })
    const { wrapper } = setup()
    const { result } = renderHook(() => useCreateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload).catch(() => undefined)
    })
    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })

    const keys = vi.mocked(pythonClient.post).mock.calls.map((c) => (c[2] as Record<string, string>)["Idempotency-Key"])
    expect(keys).toHaveLength(2)
    expect(keys[0]).toBe(keys[1])
  })

  it("la clave se resetea en cada éxito: la siguiente emisión es otra operación", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useCreateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })
    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })

    const keys = vi.mocked(pythonClient.post).mock.calls.map((c) => (c[2] as Record<string, string>)["Idempotency-Key"])
    expect(keys[0]).not.toBe(keys[1])
  })

  it("también se resetea ante un replay: la respuesta replayed=true es un éxito", async () => {
    vi.mocked(pythonClient.post).mockResolvedValue({ id: "dn-1", replayed: true })
    const { wrapper } = setup()
    const { result } = renderHook(() => useCreateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })
    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })

    const keys = vi.mocked(pythonClient.post).mock.calls.map((c) => (c[2] as Record<string, string>)["Idempotency-Key"])
    expect(keys[0]).not.toBe(keys[1])
  })

  it("una emisión fallida NO resetea la clave ni invalida nada", async () => {
    vi.mocked(pythonClient.post).mockRejectedValue(new PythonApiError("x", 409, { code: "stock_insuficiente" }))
    const { queryClient, wrapper } = setup()
    await seedCaches(queryClient)
    const { result } = renderHook(() => useCreateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload).catch(() => undefined)
    })
    await act(async () => {
      await result.current.mutateAsync(createPayload).catch(() => undefined)
    })

    const keys = vi.mocked(pythonClient.post).mock.calls.map((c) => (c[2] as Record<string, string>)["Idempotency-Key"])
    expect(keys[0]).toBe(keys[1])
    for (const [, key] of DOMAINS) expect(isInvalidated(queryClient, key)).toBe(false)
  })

  it.each(DOMAINS)("al emitir invalida %s", async (_name, key) => {
    const { queryClient, wrapper } = setup()
    await seedCaches(queryClient)
    const { result } = renderHook(() => useCreateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync(createPayload)
    })

    expect(isInvalidated(queryClient, key)).toBe(true)
  })

  it("el error del servidor llega con su code estable (no se traduce en el hook)", async () => {
    vi.mocked(pythonClient.post).mockRejectedValue(
      new PythonApiError("sin stock", 409, { code: "stock_insuficiente" }),
    )
    const { wrapper } = setup()
    const { result } = renderHook(() => useCreateDeliveryNote(), { wrapper })

    const err = await act(async () => result.current.mutateAsync(createPayload).catch((e: unknown) => e))

    expect(err).toBeInstanceOf(PythonApiError)
    expect((err as PythonApiError).code).toBe("stock_insuficiente")
  })
})

describe("useUpdateDeliveryNote — reemplazo completo con revision", () => {
  it("hace PUT /delivery-notes/{id} con el payload completo (revision incluida), sin clave", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useUpdateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ deliveryNoteId: "dn-1", payload: updatePayload })
    })

    expect(pythonClient.put).toHaveBeenCalledWith("/delivery-notes/dn-1", updatePayload)
  })

  it.each(DOMAINS)("al editar invalida %s (la edición mueve stock)", async (_name, key) => {
    const { queryClient, wrapper } = setup()
    await seedCaches(queryClient)
    const { result } = renderHook(() => useUpdateDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ deliveryNoteId: "dn-1", payload: updatePayload })
    })

    expect(isInvalidated(queryClient, key)).toBe(true)
  })

  it("delivery_note_changed (409) llega con su code y no invalida nada", async () => {
    vi.mocked(pythonClient.put).mockRejectedValue(
      new PythonApiError("cambió", 409, { code: "delivery_note_changed" }),
    )
    const { queryClient, wrapper } = setup()
    await seedCaches(queryClient)
    const { result } = renderHook(() => useUpdateDeliveryNote(), { wrapper })

    const err = await act(async () =>
      result.current.mutateAsync({ deliveryNoteId: "dn-1", payload: updatePayload }).catch((e: unknown) => e),
    )

    expect((err as PythonApiError).code).toBe("delivery_note_changed")
    for (const [, key] of DOMAINS) expect(isInvalidated(queryClient, key)).toBe(false)
  })
})

describe("useCancelDeliveryNote — anulación con motivo", () => {
  it("hace POST /delivery-notes/{id}/cancel con motivo y revision, sin header de clave", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useCancelDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ deliveryNoteId: "dn-1", payload: cancelPayload })
    })

    expect(pythonClient.post).toHaveBeenCalledTimes(1)
    const [path, body, headers] = vi.mocked(pythonClient.post).mock.calls[0]
    expect(path).toBe("/delivery-notes/dn-1/cancel")
    expect(body).toEqual(cancelPayload)
    expect(headers).toBeUndefined()
  })

  it("recorta el motivo antes de mandarlo", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useCancelDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({
        deliveryNoteId: "dn-1",
        payload: { reason: "  Error de carga  ", revision: 1 },
      })
    })

    expect(vi.mocked(pythonClient.post).mock.calls[0][1]).toEqual({ reason: "Error de carga", revision: 1 })
  })

  it.each(DOMAINS)("al anular invalida %s (devuelve stock)", async (_name, key) => {
    const { queryClient, wrapper } = setup()
    await seedCaches(queryClient)
    const { result } = renderHook(() => useCancelDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ deliveryNoteId: "dn-1", payload: cancelPayload })
    })

    expect(isInvalidated(queryClient, key)).toBe(true)
  })
})

describe("fetchDeliveryNotePdf", () => {
  it("por defecto: inline y SIN precios (show_prices=false explícito)", async () => {
    const blob = new Blob(["%PDF"], { type: "application/pdf" })
    vi.mocked(fetchDocumentPdf).mockResolvedValue(blob)

    await expect(fetchDeliveryNotePdf("dn-1")).resolves.toBe(blob)
    expect(fetchDocumentPdf).toHaveBeenCalledWith("/delivery-notes/dn-1/pdf", {
      disposition: "inline",
      show_prices: "false",
    })
  })

  it("con precios y como adjunto manda show_prices=true; el id se escapa", async () => {
    vi.mocked(fetchDocumentPdf).mockResolvedValue(null)

    await expect(fetchDeliveryNotePdf("a/b", "attachment", true)).resolves.toBeNull()
    expect(fetchDocumentPdf).toHaveBeenCalledWith("/delivery-notes/a%2Fb/pdf", {
      disposition: "attachment",
      show_prices: "true",
    })
  })
})
