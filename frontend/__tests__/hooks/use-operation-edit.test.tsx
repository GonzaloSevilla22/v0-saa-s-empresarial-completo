import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import type { ReactNode } from "react"

const getMock = vi.fn()
const postMock = vi.fn()
vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: (...a: unknown[]) => getMock(...a), post: (...a: unknown[]) => postMock(...a) },
}))

import { useOperationEditHistory } from "@/hooks/data/use-operation-edit"
import { editPreviewPath, fetchEditPreview, operationEditsPath } from "@/lib/operation-edit-api"

// edicion-operaciones-con-dinero (tanda C, 13.2/14.2): rutas por documento y carga diferida del historial.

function wrapper() {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return ({ children }: { children: ReactNode }) => <QueryClientProvider client={client}>{children}</QueryClientProvider>
}

beforeEach(() => {
  getMock.mockReset()
  postMock.mockReset()
})

describe("rutas de la edición con dinero", () => {
  it("el historial: la venta y la compra por operation_id, el gasto por su id", () => {
    expect(operationEditsPath("sale", "op-1")).toBe("/sales/operation/op-1/edits")
    expect(operationEditsPath("purchase", "op-2")).toBe("/purchases/operation/op-2/edits")
    expect(operationEditsPath("expense", "g-3")).toBe("/expenses/g-3/edits")
  })

  it("la vista previa: venta y compra sin id en la ruta, el gasto con su id", () => {
    expect(editPreviewPath("sale")).toBe("/sales/operation/edit-preview")
    expect(editPreviewPath("purchase")).toBe("/purchases/operation/edit-preview")
    expect(editPreviewPath("expense", "g-3")).toBe("/expenses/g-3/edit-preview")
  })

  it("fetchEditPreview manda el MISMO payload que el PUT, sin tocarlo", async () => {
    postMock.mockResolvedValue({ dry_run: true })
    const payload = { sale_ids: ["a"], cash_session_id: null }
    await fetchEditPreview("sale", payload)
    expect(postMock).toHaveBeenCalledWith("/sales/operation/edit-preview", payload)
  })
})

describe("useOperationEditHistory — carga diferida", () => {
  it("deshabilitado: no pide nada", async () => {
    const { result } = renderHook(() => useOperationEditHistory("sale", "op-1", false), { wrapper: wrapper() })
    expect(result.current.fetchStatus).toBe("idle")
    expect(getMock).not.toHaveBeenCalled()
  })

  it("habilitado: pide el historial del documento correcto", async () => {
    getMock.mockResolvedValue([{ id: "e1" }])
    const { result } = renderHook(() => useOperationEditHistory("expense", "g-3", true), { wrapper: wrapper() })
    await waitFor(() => expect(result.current.data).toEqual([{ id: "e1" }]))
    expect(getMock).toHaveBeenCalledWith("/expenses/g-3/edits")
  })

  it("sin id no pide nada aunque esté habilitado", () => {
    renderHook(() => useOperationEditHistory("sale", undefined, true), { wrapper: wrapper() })
    expect(getMock).not.toHaveBeenCalled()
  })
})
