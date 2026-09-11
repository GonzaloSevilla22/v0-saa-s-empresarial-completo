/**
 * useImportProducts — importador-productos-fastapi, grupo 8 (task 8.1).
 *
 * El lote pasa a ser UNA sola request a `POST /products/import`, con
 * `Idempotency-Key` por header (v3-api-standards §3/§6.2), calcado de
 * `useImportExpenses`. Cubre:
 *   - el payload EXACTO que llega a `pythonClient.post` (snake_case, filas
 *     mapeadas con `row_no`, contrato null-preserving);
 *   - la clave de idempotencia viaja en `extraHeaders`, nunca en el body;
 *   - una sola llamada para todo el archivo (sin trocear);
 *   - la mutación NO invalida sola — el diálogo decide cuándo llamar a
 *     `invalidateImportData()` (una sola vez, sólo si el lote committeó,
 *     e invalida productos + categorías + stock por sucursal).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useImportProducts } from "@/hooks/data/use-products"
import type { ProductImportInput, ProductImportResult } from "@/lib/types"

// importador-gate-plan (OQ-1, sign-off PO 2026-09-11): `plan` viaja en el
// reporte del servidor en todo camino de la RPC vigente. Corrección de
// revisión (ronda 1 adversarial, minor): sigue siendo opcional en el
// transporte (`backend/schemas/products.py` lo declara con default `None`)
// para degradar sin romper el endpoint durante la ventana de deploy en la
// que el backend ya se redesplegó pero la migración del gate todavía no
// corrió — ver el test "plan ausente" más abajo.
const PLAN_VERDICT_API = { plan: "gratis", limit: 100, before: 10, after: 12, added: 2, exceeded: false }

const APPLIED_RESULT_API = {
  committed: true,
  import_id: "import-uuid-1",
  inserted: 2,
  updated: 0,
  errors: [],
  new_categories: [{ name: "Ferretería", rows: 1 }],
  plan: PLAN_VERDICT_API,
  replayed: false,
  dry_run: false,
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

const INPUT: ProductImportInput & { idempotencyKey: string } = {
  fileName: "productos-mayo.csv",
  fileHash: "hash-abc",
  dryRun: false,
  idempotencyKey: "idem-key-1",
  rows: [
    { rowNo: 1, name: "Remera básica", price: 1000 },
    {
      rowNo: 2, name: "Pantalón", price: 2000, cost: 800, category: "Ropa", sku: "PANT-001",
      attributes: [{ key: "Talle", value: "M", sortOrder: 0 }],
    },
  ],
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("useImportProducts — payload exacto (8.1)", () => {
  it("manda UNA sola request a POST /products/import con el payload snake_case completo, row_no por fila", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(pythonClient.post).toHaveBeenCalledTimes(1)
    const [path, body, headers] = vi.mocked(pythonClient.post).mock.calls[0]
    expect(path).toBe("/products/import")
    expect(body).toEqual({
      file_name: "productos-mayo.csv",
      file_hash: "hash-abc",
      dry_run: false,
      rows: [
        {
          row_no: 1, name: "Remera básica", category: null, price: "1000", cost: null, stock: null,
          min_stock: null, barcode: null, sku: null, sku_parent: null, parent_name: null,
          is_variant: null, stock_control_type: null, attributes: [],
        },
        {
          row_no: 2, name: "Pantalón", category: "Ropa", price: "2000", cost: "800", stock: null,
          min_stock: null, barcode: null, sku: "PANT-001", sku_parent: null, parent_name: null,
          is_variant: null, stock_control_type: null,
          attributes: [{ key: "Talle", value: "M", sort_order: 0 }],
        },
      ],
    })
    expect(headers).toEqual({ "Idempotency-Key": "idem-key-1" })
  })

  it("la clave de idempotencia viaja en extraHeaders, NUNCA en el body", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync(INPUT)
    })

    const body = vi.mocked(pythonClient.post).mock.calls[0][1] as Record<string, unknown>
    expect("idempotency_key" in body).toBe(false)
    expect("idempotencyKey" in body).toBe(false)
    // El punto entero del change: tampoco viaja tenencia en el body.
    expect("user_id" in body).toBe(false)
    expect("account_id" in body).toBe(false)
  })

  it("una celda de costo AUSENTE viaja como null, nunca como \"0\" (D12, null-preserving)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync({
        ...INPUT,
        rows: [{ rowNo: 1, name: "Sin costo" }],
      })
    })

    const body = vi.mocked(pythonClient.post).mock.calls[0][1] as { rows: Array<{ cost: unknown }> }
    expect(body.rows[0].cost).toBeNull()
  })

  it("mapea la respuesta a camelCase (importId, newCategories) y conserva errors", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    let mapped
    await act(async () => {
      mapped = await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(mapped).toEqual({
      committed: true,
      importId: "import-uuid-1",
      inserted: 2,
      updated: 0,
      errors: [],
      newCategories: [{ name: "Ferretería", rows: 1 }],
      plan: { plan: "gratis", limit: 100, before: 10, after: 12, added: 2, exceeded: false },
      replayed: false,
      dryRun: false,
    })
  })

  it("propaga el veredicto de plan tal cual (exceeded=true bloquea el lote, sin transformarlo)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      ...APPLIED_RESULT_API,
      committed: false,
      import_id: null,
      plan: { plan: "gratis", limit: 100, before: 100, after: 101, added: 1, exceeded: true },
    })
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    let mapped!: ProductImportResult
    await act(async () => {
      mapped = await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(mapped.committed).toBe(false)
    expect(mapped.plan).toEqual({ plan: "gratis", limit: 100, before: 100, after: 101, added: 1, exceeded: true })
  })

  it("plan.limit === null (plan sin tope configurado) se propaga sin convertirlo a 0", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      ...APPLIED_RESULT_API,
      plan: { plan: "pro", limit: null, before: 10, after: 12, added: 2, exceeded: false },
    })
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    let mapped!: ProductImportResult
    await act(async () => {
      mapped = await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(mapped.plan?.limit).toBeNull()
  })

  it("plan ausente en la respuesta (ventana de deploy: backend nuevo + DB vieja) se mapea a null, no a un TypeError", async () => {
    // Corrección de revisión (ronda 1 adversarial, minor): antes de este fix
    // `plan` era requerido en el schema del backend y el mapper asumía
    // `r.plan.plan` sin guardas — una RPC vieja sin el campo habría lanzado
    // un TypeError acá. Ahora se degrada a `null`.
    vi.mocked(pythonClient.post).mockResolvedValueOnce({
      ...APPLIED_RESULT_API,
      plan: null,
    })
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    let mapped!: ProductImportResult
    await act(async () => {
      mapped = await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(mapped.plan).toBeNull()
    expect(mapped.committed).toBe(true)
  })

  it("la mutación NO invalida por sí sola — invalidateImportData() es una función aparte que el diálogo decide cuándo llamar", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper, queryClient } = makeWrapper()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync(INPUT)
    })
    expect(spy).not.toHaveBeenCalled()

    act(() => {
      result.current.invalidateImportData()
    })
    // Productos + categorías + stock por sucursal — los tres, task 8.8.
    expect(spy).toHaveBeenCalledTimes(3)
  })

  it("dry_run viaja en true cuando el input lo pide (vista previa validada por el servidor, D7)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ...APPLIED_RESULT_API, committed: false, dry_run: true, import_id: null })
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportProducts(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync({ ...INPUT, dryRun: true })
    })

    const body = vi.mocked(pythonClient.post).mock.calls[0][1] as Record<string, unknown>
    expect(body.dry_run).toBe(true)
  })
})
