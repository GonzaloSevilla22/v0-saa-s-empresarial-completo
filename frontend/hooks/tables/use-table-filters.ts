"use client"

import { useCallback, useMemo, useState } from "react"
import { useDebounce } from "../ui/use-debounce"

export type FilterValue = string | number | boolean | Date | null | undefined

export interface FilterDefinition {
  key: string
  type: "text" | "select" | "date" | "dateRange" | "number" | "boolean"
  defaultValue?: FilterValue
}

export interface DateRangeFilter {
  from: Date | null
  to: Date | null
}

interface TableFiltersState {
  search: string
  dateRange: DateRangeFilter
  custom: Record<string, FilterValue>
}

interface UseTableFiltersReturn {
  search: string
  debouncedSearch: string
  dateRange: DateRangeFilter
  custom: Record<string, FilterValue>
  setSearch: (value: string) => void
  setDateRange: (range: DateRangeFilter) => void
  setCustomFilter: (key: string, value: FilterValue) => void
  clearFilters: () => void
  hasActiveFilters: boolean
  activeFilterCount: number
  /** Pre-built predicate: apply to in-memory arrays */
  filterItems: <T>(items: T[], searchFn: (item: T, search: string) => boolean) => T[]
}

const DEFAULT_STATE: TableFiltersState = {
  search: "",
  dateRange: { from: null, to: null },
  custom: {},
}

/**
 * Manages all filter state for a table: text search (debounced),
 * date range, and arbitrary custom filters.
 *
 * @example
 * const filters = useTableFilters()
 *
 * const visible = filters.filterItems(products, (p, s) =>
 *   p.name.toLowerCase().includes(s) || p.sku.includes(s)
 * )
 *
 * <Input value={filters.search} onChange={(e) => filters.setSearch(e.target.value)} />
 * {filters.hasActiveFilters && (
 *   <Button onClick={filters.clearFilters}>Limpiar filtros ({filters.activeFilterCount})</Button>
 * )}
 */
export function useTableFilters(debounceMs = 300): UseTableFiltersReturn {
  const [state, setState] = useState<TableFiltersState>(DEFAULT_STATE)
  const debouncedSearch = useDebounce(state.search, debounceMs)

  const setSearch = useCallback(
    (value: string) => setState((prev) => ({ ...prev, search: value })),
    [],
  )

  const setDateRange = useCallback(
    (range: DateRangeFilter) =>
      setState((prev) => ({ ...prev, dateRange: range })),
    [],
  )

  const setCustomFilter = useCallback(
    (key: string, value: FilterValue) =>
      setState((prev) => ({
        ...prev,
        custom: { ...prev.custom, [key]: value },
      })),
    [],
  )

  const clearFilters = useCallback(() => setState(DEFAULT_STATE), [])

  const hasActiveFilters = useMemo(() => {
    const hasSearch = state.search.trim() !== ""
    const hasDate = state.dateRange.from !== null || state.dateRange.to !== null
    const hasCustom = Object.values(state.custom).some(
      (v) => v !== null && v !== undefined && v !== "",
    )
    return hasSearch || hasDate || hasCustom
  }, [state])

  const activeFilterCount = useMemo(() => {
    let count = 0
    if (state.search.trim()) count++
    if (state.dateRange.from || state.dateRange.to) count++
    count += Object.values(state.custom).filter(
      (v) => v !== null && v !== undefined && v !== "",
    ).length
    return count
  }, [state])

  const filterItems = useCallback(
    <T>(items: T[], searchFn: (item: T, search: string) => boolean): T[] => {
      return items.filter((item) => {
        if (debouncedSearch && !searchFn(item, debouncedSearch.toLowerCase())) {
          return false
        }
        return true
      })
    },
    [debouncedSearch],
  )

  return {
    search: state.search,
    debouncedSearch,
    dateRange: state.dateRange,
    custom: state.custom,
    setSearch,
    setDateRange,
    setCustomFilter,
    clearFilters,
    hasActiveFilters,
    activeFilterCount,
    filterItems,
  }
}
