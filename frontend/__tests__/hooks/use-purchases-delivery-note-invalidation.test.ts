/**
 * remitos-compra (tanda B, 7.5 y 7.8, D9/D11) — las invalidaciones de React Query
 * del ciclo de la compra, con UNA definición cada una.
 *
 * `invalidateAfterPurchaseCreate` es lo que el alta de una compra y la conversión
 * de un remito comparten: compras, productos, cuentas corrientes de proveedores,
 * `payables` (la conversión a crédito crea deuda y la pestaña "Por pagar" de
 * /cobranzas quedaría vieja) y caja, más banco y los remitos.
 *
 * `invalidateAfterPurchaseDelete` es el conjunto vigente del borrado (compras,
 * cuentas corrientes y `payables`) más los remitos: borrar una compra nacida de un
 * remito lo devuelve a `issued` en la misma transacción (R5). Sin invalidarlos,
 * `/remitos` mostraría "Convertido" con "Ver compra" apuntando a una compra
 * borrada hasta recargar.
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import {
  invalidateAfterPurchaseCreate,
  invalidateAfterPurchaseDelete,
  PURCHASE_DELETE_INVALIDATED_ROOTS,
  PURCHASE_INVALIDATED_ROOTS,
} from "@/lib/query-invalidation"
import { usePurchases } from "@/hooks/data/use-purchases"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))
import { pythonClient } from "@/lib/api/python-client"

function setup() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { queryClient, wrapper }
}

const rootsOf = (spy: ReturnType<typeof vi.spyOn>): string[] =>
  spy.mock.calls.map((c: unknown[]) => String((c[0] as { queryKey?: unknown[] })?.queryKey?.[0]))

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(pythonClient.get).mockResolvedValue({ items: [], total: 0 })
  vi.mocked(pythonClient.delete).mockResolvedValue(undefined)
  vi.mocked(pythonClient.post).mockResolvedValue({ operation_id: "op-1" })
})

describe("invalidateAfterPurchaseCreate", () => {
  it("cubre compras, productos, cuentas de proveedores, payables, caja, banco y remitos", () => {
    const { queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterPurchaseCreate(queryClient)
    const roots = rootsOf(spy)
    expect(new Set(roots)).toEqual(
      new Set([
        "purchases", "products", "supplierAccounts", "payables", "cashSessions", "cashMovements", "bankAccounts",
        "deliveryNotes",
      ]),
    )
    for (const root of PURCHASE_INVALIDATED_ROOTS) expect(roots).toContain(root)
  })

  it("invalida de verdad el detalle cacheado de un remito", async () => {
    const { queryClient } = setup()
    await queryClient.fetchQuery({ queryKey: ["deliveryNotes", "detail", "dn-1"], queryFn: async () => ({}) })
    invalidateAfterPurchaseCreate(queryClient)
    expect(queryClient.getQueryState(["deliveryNotes", "detail", "dn-1"])?.isInvalidated).toBe(true)
  })
})

describe("invalidateAfterPurchaseDelete", () => {
  it("invalida los remitos además del conjunto vigente del borrado, payables incluido", () => {
    const { queryClient } = setup()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    invalidateAfterPurchaseDelete(queryClient)
    const roots = rootsOf(spy)
    expect(roots).toContain("deliveryNotes")
    expect(roots).toContain("payables")
    for (const root of PURCHASE_DELETE_INVALIDATED_ROOTS) expect(roots).toContain(root)
    expect(new Set(roots)).toEqual(new Set([...PURCHASE_DELETE_INVALIDATED_ROOTS, "deliveryNotes"]))
  })
})

describe("usePurchases — las mutaciones usan las definiciones compartidas", () => {
  it("addPurchaseOperation invalida remitos, banco y payables (la unión del alta)", async () => {
    const { wrapper, queryClient } = setup()
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "i1", productId: "p1", productName: "A", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { idempotencyKey: "k1", date: "2026-10-15", description: "", orgId: "org" },
      })
    })

    const roots = rootsOf(spy)
    for (const root of PURCHASE_INVALIDATED_ROOTS) expect(roots).toContain(root)
    expect(roots).toContain("deliveryNotes")
  })

  it("deletePurchase (una fila) invalida deliveryNotes y payables", async () => {
    const { wrapper, queryClient } = setup()
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    await act(async () => {
      await result.current.deletePurchase("pu-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/purchases/pu-1")
    const roots = rootsOf(spy)
    expect(roots).toContain("deliveryNotes")
    expect(roots).toContain("payables")
  })

  it("deletePurchasesByOperation (la operación entera) invalida deliveryNotes y payables", async () => {
    const { wrapper, queryClient } = setup()
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    await act(async () => {
      await result.current.deletePurchasesByOperation("op-1")
    })

    expect(pythonClient.delete).toHaveBeenCalledWith("/purchases?operation_id=op-1")
    const roots = rootsOf(spy)
    expect(roots).toContain("deliveryNotes")
    expect(roots).toContain("payables")
  })

  it("un borrado que falla NO invalida nada (el remito sigue convertido)", async () => {
    const { wrapper, queryClient } = setup()
    vi.mocked(pythonClient.delete).mockRejectedValueOnce(new Error("delivery_note_purchase_delete_forbidden"))
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))
    const spy = vi.spyOn(queryClient, "invalidateQueries")

    await act(async () => {
      await expect(result.current.deletePurchasesByOperation("op-1")).rejects.toThrow()
    })

    expect(rootsOf(spy)).not.toContain("deliveryNotes")
  })
})

describe("usePurchases — el read model trae el origen del remito", () => {
  it("mapea el remito de origen, su sucursal y el motivo de no edición", async () => {
    vi.mocked(pythonClient.get).mockResolvedValue({
      items: [
        {
          id: "pu-1", date: "2026-10-15", product_id: "p1", quantity: 2, amount: "100", total: "200",
          operation_id: "op-1",
          source_delivery_note_id: "dn-1", source_delivery_note_number: 12,
          source_delivery_note_branch_active: false, edit_locked_reason: "delivery_note_purchase_locked",
        },
        { id: "pu-2", date: "2026-10-15", product_id: "p2", quantity: 1, amount: "50", total: "50", operation_id: "op-2" },
      ],
      total: 2,
    })
    const { wrapper } = setup()
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const [fromNote, plain] = result.current.purchases
    expect(fromNote.sourceDeliveryNoteId).toBe("dn-1")
    expect(fromNote.sourceDeliveryNoteNumber).toBe(12)
    expect(fromNote.sourceDeliveryNoteBranchActive).toBe(false)
    expect(fromNote.editLockedReason).toBe("delivery_note_purchase_locked")
    expect(plain.sourceDeliveryNoteId).toBeNull()
    expect(plain.sourceDeliveryNoteNumber).toBeNull()
    expect(plain.sourceDeliveryNoteBranchActive).toBeNull()
    expect(plain.editLockedReason).toBeNull()
  })
})
