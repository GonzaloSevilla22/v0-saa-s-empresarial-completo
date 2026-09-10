/**
 * asiento-contable-gastos (task 10.1) — TDD tests for useJournalEntries().
 *
 * Cycle: RED → GREEN. Mock: @/lib/api/python-client.
 *
 * Cubre: payload de filtros exacto (querystring), envoltura paginada
 * {items,total,page,pages}, clave de caché propia, y el modo "asientos de un
 * documento" (filtros iniciales fijos, D10/9.6).
 */
import { describe, it, expect, vi, beforeEach } from "vitest"
import { renderHook, waitFor, act } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import React from "react"
import { useJournalEntries } from "@/hooks/data/use-journal-entries"

vi.mock("@/lib/api/python-client", () => ({
  pythonClient: { get: vi.fn(), post: vi.fn(), put: vi.fn(), patch: vi.fn(), delete: vi.fn() },
}))

import { pythonClient } from "@/lib/api/python-client"

const mockEntryRow = {
  id: "entry-1",
  account_id: "acc-1",
  posted_at: "2026-09-05T15:00:00Z",
  status: "posted",
  source_doc_type: "Expense",
  source_doc_ref: "exp-1",
  reversal_of: null,
  created_at: "2026-09-05T15:00:00Z",
  lines: [
    { id: "l1", entry_id: "entry-1", account_code: "5300", side: "debit", amount: "1500.00", line_no: 1, cost_center_id: null },
    { id: "l2", entry_id: "entry-1", account_code: "1100", side: "credit", amount: "1500.00", line_no: 2, cost_center_id: null },
  ],
}

function makeWrapper() {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return {
    Wrapper: ({ children }: { children: React.ReactNode }) =>
      React.createElement(QueryClientProvider, { client: queryClient }, children),
  }
}

describe("useJournalEntries", () => {
  beforeEach(() => {
    vi.clearAllMocks()
    vi.mocked(pythonClient.get).mockResolvedValue({ items: [mockEntryRow], total: 1, page: 0, pages: 1 })
  })

  it("consulta GET /journal-entries sin filtros por defecto", async () => {
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useJournalEntries(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(pythonClient.get).toHaveBeenCalledTimes(1)
    const url = vi.mocked(pythonClient.get).mock.calls[0][0] as string
    expect(url).toContain("/journal-entries?")
    expect(url).not.toContain("source_doc_type")
    expect(url).not.toContain("source_doc_ref")
    expect(url).not.toContain("status")
  })

  it("mapea la envoltura paginada {items,total,page,pages}", async () => {
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useJournalEntries(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    expect(result.current.entries).toHaveLength(1)
    expect(result.current.entries[0].id).toBe("entry-1")
    expect(result.current.entries[0].lines).toHaveLength(2)
    expect(result.current.meta.totalCount).toBe(1)
  })

  it("mapea cada línea con su account_code/side/amount (camelCase)", async () => {
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useJournalEntries(), { wrapper: Wrapper })

    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const [debit, credit] = result.current.entries[0].lines
    expect(debit).toMatchObject({ accountCode: "5300", side: "debit", amount: 1500 })
    expect(credit).toMatchObject({ accountCode: "1100", side: "credit", amount: 1500 })
  })

  it("setFilters manda los cinco filtros exactos en la querystring", async () => {
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useJournalEntries(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => {
      result.current.setFilters({
        dateFrom: "2026-09-01", dateTo: "2026-09-30",
        sourceDocType: "Expense", sourceDocRef: "exp-9", status: "posted",
      })
    })

    await waitFor(() => expect(pythonClient.get).toHaveBeenCalledTimes(2))
    const url = vi.mocked(pythonClient.get).mock.calls[1][0] as string
    expect(url).toContain("from=2026-09-01")
    expect(url).toContain("to=2026-09-30")
    expect(url).toContain("source_doc_type=Expense")
    expect(url).toContain("source_doc_ref=exp-9")
    expect(url).toContain("status=posted")
  })

  it("cambiar filtros vuelve a la página 0", async () => {
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(() => useJournalEntries(), { wrapper: Wrapper })
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    act(() => result.current.setPage(2))
    act(() => result.current.setFilters({ status: "posted" }))

    await waitFor(() => {
      const url = vi.mocked(pythonClient.get).mock.calls.at(-1)?.[0] as string
      expect(url).toContain("page=0")
    })
  })

  it("modo 'asientos de un documento': filtros iniciales fijos (9.6)", async () => {
    const { Wrapper } = makeWrapper()
    const { result } = renderHook(
      () => useJournalEntries({ initialFilters: { sourceDocType: "Expense", sourceDocRef: "exp-1" } }),
      { wrapper: Wrapper },
    )
    await waitFor(() => expect(result.current.isLoading).toBe(false))

    const url = vi.mocked(pythonClient.get).mock.calls[0][0] as string
    expect(url).toContain("source_doc_type=Expense")
    expect(url).toContain("source_doc_ref=exp-1")
  })

  it("usa una clave de caché propia (journal-entries), distinta de expenses", async () => {
    const { Wrapper } = makeWrapper()
    renderHook(() => useJournalEntries(), { wrapper: Wrapper })
    await waitFor(() => expect(pythonClient.get).toHaveBeenCalled())
    // La prueba indirecta: el queryFn llama al endpoint correcto — la clave en
    // sí se verifica por inspección de queryKeys.journalEntries en su propio
    // archivo; acá se confirma que no colisiona con /expenses.
    const url = vi.mocked(pythonClient.get).mock.calls[0][0] as string
    expect(url.startsWith("/journal-entries")).toBe(true)
  })
})
