"use client"

/**
 * asiento-contable-gastos (D10) — hook de lectura para el libro diario.
 *
 * `GET /journal-entries` existe completo desde `journal-entry-outbox` (router,
 * service, repository, schemas Pydantic, tests) con CERO consumidores en el
 * frontend — es el anti-patrón textual que la regla de superficie del PO
 * existe para prevenir (`CLAUDE.md`, origen: `CostCenterManager`).
 *
 * Sólo lectura: el relay es el único escritor de asientos (SECURITY DEFINER).
 * Los cinco filtros son opcionales y viajan tal cual al backend (D10) — nunca
 * se filtran en el cliente.
 */
import { useMemo, useState, useCallback } from "react"
import { useQuery } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { JournalEntry, JournalEntryFilters, JournalLine } from "@/lib/types"
import {
  buildPaginationMeta,
  type PaginationMeta,
  type PageSizeOption,
} from "@/lib/pagination-utils"

// ── API response shapes ───────────────────────────────────────────────────────

interface JournalLineApiRow {
  id: string
  entry_id: string
  account_code: string
  side: "debit" | "credit"
  amount: string | number
  line_no: number
  cost_center_id: string | null
}

interface JournalEntryApiRow {
  id: string
  account_id: string
  posted_at: string
  status: "posted" | "reversed"
  source_doc_type: string | null
  source_doc_ref: string | null
  reversal_of: string | null
  created_at: string
  lines: JournalLineApiRow[]
}

interface JournalEntriesPageResponse {
  items: JournalEntryApiRow[]
  total: number
  page?: number
  pages?: number
}

function mapLine(l: JournalLineApiRow): JournalLine {
  return {
    id:           l.id,
    entryId:      l.entry_id,
    accountCode:  l.account_code,
    side:         l.side,
    amount:       Number(l.amount),
    lineNo:       l.line_no,
    costCenterId: l.cost_center_id,
  }
}

function mapEntry(e: JournalEntryApiRow): JournalEntry {
  return {
    id:            e.id,
    accountId:     e.account_id,
    postedAt:      e.posted_at,
    status:        e.status,
    sourceDocType: e.source_doc_type,
    sourceDocRef:  e.source_doc_ref,
    reversalOf:    e.reversal_of,
    createdAt:     e.created_at,
    lines:         (e.lines ?? []).map(mapLine),
  }
}

export interface UseJournalEntriesOptions {
  /** Filtros iniciales — el modo "asientos de un documento" (9.6) los pasa fijos. */
  initialFilters?: JournalEntryFilters
}

/**
 * Origen de datos de `/reportes/libro-diario`: paginado server-side, con los
 * cinco filtros de D10. Payload exacto y clave de caché propia (task 10.1).
 */
export function useJournalEntries(options: UseJournalEntriesOptions = {}) {
  const [page,     setPageState]     = useState(0)
  const [pageSize, setPageSizeState] = useState<PageSizeOption>(25)
  const [filters,  setFiltersState]  = useState<JournalEntryFilters>(options.initialFilters ?? {})

  const setPage = useCallback((p: number) => setPageState(p), [])
  const setPageSize = useCallback((s: PageSizeOption) => {
    setPageSizeState(s)
    setPageState(0)
  }, [])
  const setFilters = useCallback((next: JournalEntryFilters) => {
    setFiltersState(next)
    setPageState(0)
  }, [])

  const queryParams = useMemo(() => {
    const p: Record<string, string> = {
      page: String(page),
      size: String(pageSize),
    }
    if (filters.dateFrom)      p.from             = filters.dateFrom
    if (filters.dateTo)        p.to               = filters.dateTo
    if (filters.sourceDocType) p.source_doc_type  = filters.sourceDocType
    if (filters.sourceDocRef)  p.source_doc_ref   = filters.sourceDocRef
    if (filters.status)        p.status           = filters.status
    return p
  }, [page, pageSize, filters])

  const query = useQuery({
    queryKey: [...queryKeys.journalEntries.lists(), queryParams],
    queryFn: async (): Promise<JournalEntriesPageResponse> => {
      const qs = new URLSearchParams(queryParams).toString()
      return pythonClient.get<JournalEntriesPageResponse>(`/journal-entries?${qs}`)
    },
    staleTime: 30 * 1000,
  })

  const entries = useMemo(
    () => (query.data?.items ?? []).map(mapEntry),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total ?? 0),
    [page, pageSize, query.data?.total],
  )

  return {
    entries,
    meta,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error,
    refetch:   query.refetch,
    filters,   setFilters,
    setPage,
    setPageSize,
  }
}
