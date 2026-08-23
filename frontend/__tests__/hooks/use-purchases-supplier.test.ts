/**
 * usePurchases — mapper + passthrough de supplier_id (compras-proveedor-cuenta-corriente,
 * task 10.4). Espejo exacto de use-purchases-payment-method.test.ts: alta SIEMPRE manda la
 * clave (D4: atributo de operación); edición usa el contrato tri-estado por AUSENCIA
 * (D7 — nunca por valor).
 *
 * Ciclo: RED → GREEN → TRIANGULATE
 * Mock: @/lib/api/python-client
 */

import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { usePurchases } from "@/hooks/data/use-purchases"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: {
    get:    vi.fn(),
    post:   vi.fn(),
    put:    vi.fn(),
    delete: vi.fn(),
  },
}))

import { pythonClient } from "@/lib/api/python-client"

const SUPPLIER_ID = "sup-1111"

function makeWrapper() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  return ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
}

// fix-supplier-account-ui-post-delete (bug 1): igual que makeWrapper, pero
// devuelve también el QueryClient para poder espiar invalidateQueries.
function makeWrapperWithClient() {
  const queryClient = new QueryClient({
    defaultOptions: { queries: { retry: false } },
  })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

beforeEach(() => {
  vi.clearAllMocks()
  ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValue({
    items: [], total: 0, page: 0, pages: 0,
  })
  ;(pythonClient.post as ReturnType<typeof vi.fn>).mockResolvedValue({ operation_id: "op-1" })
  ;(pythonClient.put as ReturnType<typeof vi.fn>).mockResolvedValue(undefined)
})

describe("usePurchases — mapper de supplier_id/supplier_name", () => {
  it("mapea supplier_id/supplier_name de la fila al Purchase", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      items: [{
        id: "pu-1", date: "2026-08-20", product_id: "p1", product_name: "X",
        quantity: 1, amount: 10, total: 10,
        supplier_id: SUPPLIER_ID, supplier_name: "Distribuidora Mendoza",
      }],
      total: 1, page: 0, pages: 1,
    })

    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.purchases).toHaveLength(1))

    expect(result.current.purchases[0].supplierId).toBe(SUPPLIER_ID)
    expect(result.current.purchases[0].supplierName).toBe("Distribuidora Mendoza")
  })

  it("fila sin proveedor mapea a null", async () => {
    ;(pythonClient.get as ReturnType<typeof vi.fn>).mockResolvedValueOnce({
      items: [{
        id: "pu-2", date: "2026-08-20", product_id: "p1", product_name: "X",
        quantity: 1, amount: 10, total: 10,
      }],
      total: 1, page: 0, pages: 1,
    })

    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(result.current.purchases).toHaveLength(1))

    expect(result.current.purchases[0].supplierId).toBeNull()
    expect(result.current.purchases[0].supplierName).toBeNull()
  })
})

describe("usePurchases — passthrough de supplier_id en el alta", () => {
  it("addPurchaseOperation manda supplier_id en el body", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { idempotencyKey: "k1", date: "2026-08-19", description: "", orgId: "acc-1", supplierId: SUPPLIER_ID },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.supplier_id).toBe(SUPPLIER_ID)
  })

  it("addPurchaseOperation sin proveedor manda NULL", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { idempotencyKey: "k1", date: "2026-08-19", description: "", orgId: "acc-1" },
      })
    })

    const [, body] = (pythonClient.post as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.supplier_id).toBeNull()
  })
})

describe("usePurchases — passthrough tri-estado de supplier_id en la edición (D7)", () => {
  it("supplierId AUSENTE del meta no incluye la clave en el body (preserva el vigente)", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchaseOperation({
        purchaseIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { date: "2026-08-19", description: "", orgId: "acc-1" },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("supplier_id" in body).toBe(false)
  })

  it("supplierId=null EXPLÍCITO desimputa", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchaseOperation({
        purchaseIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { date: "2026-08-19", description: "", orgId: "acc-1", supplierId: null },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect("supplier_id" in body).toBe(true)
    expect(body.supplier_id).toBeNull()
  })

  it("supplierId=uuid reimputa", async () => {
    const { result } = renderHook(() => usePurchases(), { wrapper: makeWrapper() })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchaseOperation({
        purchaseIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { date: "2026-08-19", description: "", orgId: "acc-1", supplierId: SUPPLIER_ID },
      })
    })

    const [, body] = (pythonClient.put as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(body.supplier_id).toBe(SUPPLIER_ID)
  })
})

// fix-supplier-account-ui-post-delete (bug 1): una compra a crédito postea un
// cargo en supplierAccounts y un borrado lo revierte, pero las mutaciones de
// usePurchases solo invalidaban purchases/products — la cuenta corriente del
// proveedor quedaba con datos stale (staleTime 30s en useSupplierAccount)
// hasta que algo más disparara un refetch. Reporte PO 2026-08-22: creó,
// pagó, creó y borró una compra a crédito; la DB quedó en $0 pero
// /proveedores/[id]/cuenta seguía mostrando $8.400 y 3 movimientos.
describe("usePurchases — invalida supplierAccounts tras crear/editar/borrar (bug post-delete)", () => {
  it("addPurchaseOperation invalida supplierAccounts", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.addPurchaseOperation({
        items: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { idempotencyKey: "k1", date: "2026-08-19", description: "", orgId: "acc-1", supplierId: SUPPLIER_ID },
      })
    })

    expect(spy.mock.calls.some((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0] === "supplierAccounts")).toBe(true)
  })

  it("updatePurchase invalida supplierAccounts", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchase({
        id: "pu-1", date: "2026-08-19", productId: "p1", productName: "X",
        quantity: 1, unitCost: 10, total: 10,
      })
    })

    expect(spy.mock.calls.some((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0] === "supplierAccounts")).toBe(true)
  })

  it("deletePurchase invalida supplierAccounts (la reversa del cargo)", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.deletePurchase("pu-1")
    })

    expect(spy.mock.calls.some((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0] === "supplierAccounts")).toBe(true)
  })

  it("deletePurchasesByOperation invalida supplierAccounts", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.deletePurchasesByOperation("op-1")
    })

    expect(spy.mock.calls.some((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0] === "supplierAccounts")).toBe(true)
  })

  it("updatePurchaseOperation invalida supplierAccounts", async () => {
    const { wrapper, queryClient } = makeWrapperWithClient()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => usePurchases(), { wrapper })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())

    await act(async () => {
      await result.current.updatePurchaseOperation({
        purchaseIds: ["1"],
        newItems: [{ id: "1", productId: "p1", productName: "X", unitCost: 10, quantity: 1, subtotal: 10 }],
        meta: { date: "2026-08-19", description: "", orgId: "acc-1", supplierId: SUPPLIER_ID },
      })
    })

    expect(spy.mock.calls.some((c) => (c[0] as { queryKey?: unknown[] })?.queryKey?.[0] === "supplierAccounts")).toBe(true)
  })
})
