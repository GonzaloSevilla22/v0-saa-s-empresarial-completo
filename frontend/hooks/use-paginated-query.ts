"use client"

/**
 * usePaginatedQuery — generic server-side pagination hook for Supabase tables.
 *
 * Features:
 *   - LIMIT/OFFSET via Supabase .range(from, to)
 *   - Parallel count + data queries (single round-trip cost)
 *   - Debounced search (300 ms default)
 *   - AbortController — in-flight request cancelled on param change
 *   - Configurable page size (10 / 25 / 50 / 100)
 *   - Sort key + direction (applied by hook via .order())
 *   - Date range filters delegated to caller's applyFilters
 *   - Screen-owned extra filters via `extraFilters` (dep-aware: refetch + page 0)
 *
 * Usage:
 *   const q = usePaginatedQuery<Expense>({
 *     table: "expenses",
 *     applyFilters: (base, { search, dateFrom, dateTo }) => {
 *       let q = base
 *       if (search)   q = q.ilike("description", `%${search}%`)
 *       if (dateFrom) q = q.gte("date", dateFrom)
 *       if (dateTo)   q = q.lte("date", dateTo)
 *       return q
 *     },
 *     defaultSortKey: "date",
 *   })
 *
 * With a screen-owned filter (cost-center-surface) — pass it through
 * `extraFilters` instead of capturing it in the applyFilters closure, or the
 * query will not refetch when it changes:
 *   const [costCenterId, setCostCenterId] = useState<string | null>(null)
 *   const q = usePaginatedQuery<Expense>({
 *     table: "expenses",
 *     extraFilters: { cost_center_id: costCenterId },
 *     applyFilters: (base, { search, extraFilters }) => {
 *       let q = base
 *       if (search) q = q.ilike("description", `%${search}%`)
 *       if (extraFilters?.cost_center_id) q = q.eq("cost_center_id", extraFilters.cost_center_id)
 *       return q
 *     },
 *   })
 */

import { useState, useEffect, useCallback, useRef, useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import {
  PAGE_SIZE_OPTIONS,
  type PageSizeOption,
  type FilterParams,
  type ApplyFilters,
  type PaginationMeta,
  buildPaginationMeta,
} from "@/lib/pagination-utils"

// ─── Public types ─────────────────────────────────────────────────────────────

export interface UsePaginatedQueryOptions {
  table:            string
  select?:          string
  applyFilters:     ApplyFilters
  defaultSortKey?:  string | null
  defaultSortDir?:  "asc" | "desc"
  defaultPageSize?: PageSizeOption
  debounceMs?:      number
  /**
   * Filtros extra controlados por la pantalla (p. ej. `{ cost_center_id }`).
   * Llegan a `applyFilters` dentro de `params.extraFilters` y forman parte de
   * las deps del fetch: cambiarlos refetchea y vuelve a la página 0.
   *
   * Sin esto, un filtro capturado en el closure de `applyFilters` se guardaría
   * en el ref pero no dispararía refetch — se aplicaría recién en la próxima
   * búsqueda o cambio de página.
   */
  extraFilters?:    Record<string, string | null>
}

export interface UsePaginatedQueryResult<T> {
  data:        T[]
  meta:        PaginationMeta
  loading:     boolean
  error:       string | null
  // Filter state
  search:      string
  setSearch:   (v: string) => void
  dateFrom:    string
  setDateFrom: (v: string) => void
  dateTo:      string
  setDateTo:   (v: string) => void
  clearFilters:() => void
  // Sort state
  sortKey:     string | null
  sortDir:     "asc" | "desc"
  setSort:     (key: string) => void
  // Pagination controls
  setPage:     (p: number) => void
  setPageSize: (s: PageSizeOption) => void
  // Manual refetch (call after mutations)
  refetch:     () => void
}

// ─── Hook ─────────────────────────────────────────────────────────────────────

export function usePaginatedQuery<T = any>({
  table,
  select = "*",
  applyFilters,
  defaultSortKey  = null,
  defaultSortDir  = "desc",
  defaultPageSize = 25,
  debounceMs      = 300,
  extraFilters,
}: UsePaginatedQueryOptions): UsePaginatedQueryResult<T> {
  const supabase = useMemo(() => createClient(), [])

  // ── State ──────────────────────────────────────────────────────────────────
  const [data,      setData]      = useState<T[]>([])
  const [total,     setTotal]     = useState(0)
  const [page,      setPageState] = useState(0)
  const [pageSize,  setSizeState] = useState<PageSizeOption>(defaultPageSize)
  const [search,    setSearchRaw] = useState("")
  const [debSearch, setDebSearch] = useState("")
  const [dateFrom,  setDfRaw]     = useState("")
  const [dateTo,    setDtRaw]     = useState("")
  const [sortKey,   setSortKey]   = useState<string | null>(defaultSortKey)
  const [sortDir,   setSortDir]   = useState<"asc" | "desc">(defaultSortDir)
  const [loading,   setLoading]   = useState(true)
  const [error,     setError]     = useState<string | null>(null)

  const debTimerRef      = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)
  const abortRef         = useRef<AbortController | undefined>(undefined)
  const applyFiltersRef  = useRef<ApplyFilters>(applyFilters)
  applyFiltersRef.current = applyFilters

  // ── Filtros extra de la pantalla ─────────────────────────────────────────
  // El objeto suele venir como literal inline (identidad nueva en cada
  // render), así que las deps del fetch cuelgan de su forma serializada y no
  // de su identidad.
  const extraFiltersKey = useMemo(
    () => (extraFilters ? JSON.stringify(extraFilters) : ""),
    [extraFilters],
  )
  const extraFiltersRef = useRef(extraFilters)
  extraFiltersRef.current = extraFilters

  // Volver a la página 0 cuando cambia un filtro externo, con el patrón de
  // ajuste de estado durante el render (React docs, "adjusting state when a
  // prop changes"): React re-renderiza antes de commitear, así que NO se
  // dispara un fetch intermedio con la página vieja.
  const [seenExtraKey, setSeenExtraKey] = useState(extraFiltersKey)
  if (seenExtraKey !== extraFiltersKey) {
    setSeenExtraKey(extraFiltersKey)
    setPageState(0)
  }

  // ── Setters that reset to page 0 ─────────────────────────────────────────
  const setSearch = useCallback((v: string) => {
    setSearchRaw(v)
    setPageState(0)
    clearTimeout(debTimerRef.current)
    debTimerRef.current = setTimeout(() => setDebSearch(v), debounceMs)
  }, [debounceMs])

  const setDateFrom = useCallback((v: string) => { setDfRaw(v); setPageState(0) }, [])
  const setDateTo   = useCallback((v: string) => { setDtRaw(v); setPageState(0) }, [])

  const setPage = useCallback((p: number) => setPageState(p), [])

  const setPageSize = useCallback((s: PageSizeOption) => {
    setSizeState(s)
    setPageState(0)
  }, [])

  const setSort = useCallback((key: string) => {
    setSortKey((prev) => {
      if (prev === key) {
        setSortDir((d) => (d === "asc" ? "desc" : "asc"))
        return prev
      }
      setSortDir("desc")
      return key
    })
    setPageState(0)
  }, [])

  const clearFilters = useCallback(() => {
    setSearchRaw("")
    setDebSearch("")
    setDfRaw("")
    setDtRaw("")
    setPageState(0)
  }, [])

  // ── Fetch ─────────────────────────────────────────────────────────────────
  const fetchPage = useCallback(async () => {
    abortRef.current?.abort()
    const ctrl = new AbortController()
    abortRef.current = ctrl

    setLoading(true)
    setError(null)

    const params: FilterParams = {
      search: debSearch, dateFrom, dateTo, sortKey, sortDir,
      extraFilters: extraFiltersRef.current,
    }
    const from = page * pageSize
    const to   = from + pageSize - 1

    try {
      // Count query — head:true returns no rows, only the count header
      const countBase = supabase.from(table).select("*", { count: "exact", head: true })
      const countQ    = applyFiltersRef.current(countBase, params)
      const { count, error: cErr } = await countQ
      if (ctrl.signal.aborted) return
      if (cErr) throw cErr

      // Data query — same filters + order + range
      const dataBase = supabase.from(table).select(select)
      let   dataQ    = applyFiltersRef.current(dataBase, params)
      if (sortKey) dataQ = dataQ.order(sortKey, { ascending: sortDir === "asc" })
      dataQ = dataQ.range(from, to)

      const { data: rows, error: dErr } = await dataQ
      if (ctrl.signal.aborted) return
      if (dErr) throw dErr

      setTotal(count ?? 0)
      setData(rows ?? [])
    } catch (err: any) {
      if (!ctrl.signal.aborted) {
        setError(err?.message ?? "Error al cargar datos")
      }
    } finally {
      if (!ctrl.signal.aborted) setLoading(false)
    }
  }, [
    supabase, table, select,
    page, pageSize, debSearch, dateFrom, dateTo, sortKey, sortDir,
    // Serializado, no el objeto: un literal inline cambiaría de identidad en
    // cada render y refetchearía en loop.
    extraFiltersKey,
  ])

  useEffect(() => { fetchPage() }, [fetchPage])

  // Cleanup on unmount
  useEffect(() => () => {
    abortRef.current?.abort()
    clearTimeout(debTimerRef.current)
  }, [])

  const meta = buildPaginationMeta(page, pageSize, total)

  return {
    data, meta, loading, error,
    search,   setSearch,
    dateFrom, setDateFrom,
    dateTo,   setDateTo,
    clearFilters,
    sortKey,  sortDir, setSort,
    setPage,  setPageSize,
    refetch: fetchPage,
  }
}
