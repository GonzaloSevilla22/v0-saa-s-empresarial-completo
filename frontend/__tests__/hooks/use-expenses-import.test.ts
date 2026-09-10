/**
 * useImportExpenses — importador-gastos-transaccional, grupo 7 (task 7.1).
 *
 * El lote pasa a ser UNA sola request a `POST /expenses/import`, con
 * `Idempotency-Key` por header (v3-api-standards §3/§6.2, mismo patrón que
 * `useImportStatement` de bank-reconciliation). Cubre:
 *   - el payload EXACTO que llega a `pythonClient.post` (snake_case, los
 *     cuatro defaults del lote, las filas mapeadas);
 *   - la clave de idempotencia viaja en `extraHeaders`, nunca en el body;
 *   - la mutación NO invalida sola — el diálogo decide cuándo llamar a
 *     `invalidateLedgers()` (una sola vez, sólo si el lote committeó).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"
import { useImportExpenses } from "@/hooks/data/use-expenses-query"
import type { ExpenseImportInput } from "@/lib/types"

const APPLIED_RESULT_API = {
  committed: true,
  import_id: "import-uuid-1",
  imported: 2,
  errors: [],
  notices: [{ row: 1, code: "cash_not_posted", message: "sin impacto en caja" }],
  replayed: false,
  dry_run: false,
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  const wrapper = ({ children }: { children: React.ReactNode }) =>
    React.createElement(QueryClientProvider, { client: queryClient }, children)
  return { wrapper, queryClient }
}

const INPUT: ExpenseImportInput & { idempotencyKey: string } = {
  fileName: "gastos-mayo.csv",
  fileHash: "hash-abc",
  dryRun: false,
  defaultPaymentMethodId: "pm-1",
  defaultBranchId: null,
  defaultCostCenterId: null,
  fallbackBankAccountId: "ba-1",
  idempotencyKey: "idem-key-1",
  rows: [
    { rowNo: 1, description: "Alquiler", category: "Alquiler", amount: 1000, date: "2026-05-01" },
    {
      rowNo: 2, description: "Internet", category: "Servicios", amount: 2000, date: "2026-05-02",
      paymentMethodName: "Transferencia bancaria", branchName: "Centro", costCenterName: "Admin",
    },
  ],
}

beforeEach(() => {
  vi.clearAllMocks()
})

describe("useImportExpenses — payload exacto (7.1)", () => {
  it("manda UNA sola request a POST /expenses/import con el payload snake_case completo", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportExpenses(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(pythonClient.post).toHaveBeenCalledTimes(1)
    const [path, body, headers] = vi.mocked(pythonClient.post).mock.calls[0]
    expect(path).toBe("/expenses/import")
    expect(body).toEqual({
      file_name: "gastos-mayo.csv",
      file_hash: "hash-abc",
      dry_run: false,
      default_payment_method_id: "pm-1",
      default_branch_id: null,
      default_cost_center_id: null,
      fallback_bank_account_id: "ba-1",
      rows: [
        { row_no: 1, description: "Alquiler", category: "Alquiler", amount: 1000, date: "2026-05-01", payment_method_name: null, branch_name: null, cost_center_name: null },
        { row_no: 2, description: "Internet", category: "Servicios", amount: 2000, date: "2026-05-02", payment_method_name: "Transferencia bancaria", branch_name: "Centro", cost_center_name: "Admin" },
      ],
    })
    expect(headers).toEqual({ "Idempotency-Key": "idem-key-1" })
  })

  it("la clave de idempotencia viaja en extraHeaders, NUNCA en el body", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportExpenses(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync(INPUT)
    })

    const body = vi.mocked(pythonClient.post).mock.calls[0][1] as Record<string, unknown>
    expect("idempotency_key" in body).toBe(false)
    expect("idempotencyKey" in body).toBe(false)
  })

  it("mapea la respuesta a camelCase (importId, dryRun) y conserva errors/notices", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportExpenses(), { wrapper })

    let mapped
    await act(async () => {
      mapped = await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(mapped).toEqual({
      committed: true,
      importId: "import-uuid-1",
      imported: 2,
      errors: [],
      notices: [{ row: 1, code: "cash_not_posted", message: "sin impacto en caja" }],
      replayed: false,
      dryRun: false,
    })
  })

  it("la mutación NO invalida por sí sola — invalidateLedgers() es una función aparte que el diálogo decide cuándo llamar", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce(APPLIED_RESULT_API)
    const { wrapper, queryClient } = makeWrapper()
    const spy = vi.spyOn(queryClient, "invalidateQueries")
    const { result } = renderHook(() => useImportExpenses(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync(INPUT)
    })

    expect(spy).not.toHaveBeenCalled()

    act(() => {
      result.current.invalidateLedgers()
    })
    expect(spy).toHaveBeenCalled()
  })

  it("dry_run viaja en true cuando el input lo pide (vista previa validada por el servidor, D9)", async () => {
    vi.mocked(pythonClient.post).mockResolvedValueOnce({ ...APPLIED_RESULT_API, committed: false, dry_run: true, import_id: null })
    const { wrapper } = makeWrapper()
    const { result } = renderHook(() => useImportExpenses(), { wrapper })

    await act(async () => {
      await result.current.importMutation.mutateAsync({ ...INPUT, dryRun: true })
    })

    const body = vi.mocked(pythonClient.post).mock.calls[0][1] as Record<string, unknown>
    expect(body.dry_run).toBe(true)
  })
})
