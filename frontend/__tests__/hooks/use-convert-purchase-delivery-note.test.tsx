/**
 * remitos-compra (tanda B, 7.5, D8/D11) — `useConvertPurchaseDeliveryNote`: la
 * conversión atómica del remito de compra en compra
 * (`POST /delivery-notes/{id}/convert-to-purchase`).
 *
 * Invariantes bajo test:
 *  - la clave de idempotencia viaja SIEMPRE por el header `Idempotency-Key`
 *    (nunca en el cuerpo) y la pone quien llama: es POR remito;
 *  - el cuerpo es el contrato de `PurchaseDeliveryNoteConvertIn` — sin
 *    `supplier_id`, `branch_id`, `items` ni origen (la compra se imputa al
 *    proveedor y a la sucursal del remito, y las líneas las lee el servidor);
 *  - un éxito (también el replay) invalida los remitos Y todo lo que toca una
 *    compra (`invalidateAfterPurchaseCreate`, `payables` incluido: la conversión a
 *    crédito crea deuda);
 *  - un fallo no invalida nada: la conversión es una transacción.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))
vi.mock("@/lib/api/document-pdf", () => ({ fetchDocumentPdf: vi.fn() }))

import { pythonClient } from "@/lib/api/python-client"
import { PythonApiError } from "@/lib/api/python-api-error"
import { useConvertPurchaseDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { PURCHASE_INVALIDATED_ROOTS } from "@/lib/query-invalidation"
import type {
  PurchaseDeliveryNoteConvertInput,
  PurchaseDeliveryNoteConvertResult,
} from "@/lib/delivery-note-types"

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { queryClient, wrapper }
}

const payload: PurchaseDeliveryNoteConvertInput = {
  expected_revision: 3,
  payment_method_id: "pm-1",
  date: "2026-10-15",
  cash_session_id: null,
  bank_account_id: "ba-1",
  cost_center_id: null,
  due_date: "2026-11-14",
  description: null,
}

const RESULT: PurchaseDeliveryNoteConvertResult = {
  delivery_note_id: "dn-1",
  delivery_note_number: 12,
  delivery_note_number_label: "RC-00000012",
  operation_id: "op-1",
  total: "4500.00",
  replayed: false,
}

const rootsOf = (spy: ReturnType<typeof vi.spyOn>): string[] =>
  spy.mock.calls.map((c: unknown[]) => String((c[0] as { queryKey?: unknown[] })?.queryKey?.[0]))

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(pythonClient.post).mockResolvedValue(RESULT)
})

describe("useConvertPurchaseDeliveryNote", () => {
  it("POST /delivery-notes/{id}/convert-to-purchase con la clave por header y el cuerpo del contrato", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useConvertPurchaseDeliveryNote(), { wrapper })

    let out: PurchaseDeliveryNoteConvertResult | undefined
    await act(async () => {
      out = await result.current.mutateAsync({ deliveryNoteId: "dn-1", payload, idempotencyKey: "idem-1" })
    })

    expect(out).toEqual(RESULT)
    expect(pythonClient.post).toHaveBeenCalledTimes(1)
    expect(pythonClient.post).toHaveBeenCalledWith("/delivery-notes/dn-1/convert-to-purchase", payload, {
      "Idempotency-Key": "idem-1",
    })
    const body = vi.mocked(pythonClient.post).mock.calls[0][1] as Record<string, unknown>
    for (const forbidden of ["idempotency_key", "branch_id", "supplier_id", "items", "source_delivery_note_id"]) {
      expect(body).not.toHaveProperty(forbidden)
    }
  })

  it("dos remitos distintos usan su propia ruta y su propia clave", async () => {
    const { wrapper } = setup()
    const { result } = renderHook(() => useConvertPurchaseDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ deliveryNoteId: "dn-A", payload, idempotencyKey: "key-A" })
      await result.current.mutateAsync({ deliveryNoteId: "dn-B", payload, idempotencyKey: "key-B" })
    })

    expect(
      vi.mocked(pythonClient.post).mock.calls.map((c) => [c[0], (c[2] as Record<string, string>)["Idempotency-Key"]]),
    ).toEqual([
      ["/delivery-notes/dn-A/convert-to-purchase", "key-A"],
      ["/delivery-notes/dn-B/convert-to-purchase", "key-B"],
    ])
  })

  it("un éxito invalida los remitos y la unión de lo que toca una compra, payables incluido", async () => {
    const { wrapper, queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useConvertPurchaseDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ deliveryNoteId: "dn-1", payload, idempotencyKey: "idem-1" })
    })

    const roots = rootsOf(spy)
    expect(roots).toContain("deliveryNotes")
    expect(roots).toContain("payables")
    for (const root of PURCHASE_INVALIDATED_ROOTS) expect(roots).toContain(root)
  })

  it("el replay (replayed: true) también invalida: la compra ya existe", async () => {
    vi.mocked(pythonClient.post).mockResolvedValue({ ...RESULT, replayed: true })
    const { wrapper, queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useConvertPurchaseDeliveryNote(), { wrapper })

    await act(async () => {
      await result.current.mutateAsync({ deliveryNoteId: "dn-1", payload, idempotencyKey: "idem-1" })
    })

    expect(rootsOf(spy)).toContain("deliveryNotes")
  })

  it("un fallo propaga el error tal cual y no invalida nada", async () => {
    const err = new PythonApiError("delivery_note_changed", 409, { code: "delivery_note_changed" })
    vi.mocked(pythonClient.post).mockRejectedValue(err)
    const { wrapper, queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useConvertPurchaseDeliveryNote(), { wrapper })

    await act(async () => {
      await expect(
        result.current.mutateAsync({ deliveryNoteId: "dn-1", payload, idempotencyKey: "idem-1" }),
      ).rejects.toBe(err)
    })

    expect(spy).not.toHaveBeenCalled()
  })
})
