"use client"

import { useCallback, useMemo } from "react"
import { usePersistentState } from "../persistence/use-persistent-state"

export type ColumnVisibility = Record<string, boolean>
export type SortDirection = "asc" | "desc"
export type TableDensity = "compact" | "normal" | "comfortable"

export interface TablePreferences {
  columnVisibility: ColumnVisibility
  columnOrder: string[]
  columnWidths: Record<string, number>
  sortKey: string | null
  sortDirection: SortDirection
  density: TableDensity
  pageSize: number
  filters: Record<string, unknown>
}

const DEFAULT_PREFERENCES: TablePreferences = {
  columnVisibility: {},
  columnOrder: [],
  columnWidths: {},
  sortKey: null,
  sortDirection: "desc",
  density: "normal",
  pageSize: 25,
  filters: {},
}

interface UseTablePreferencesReturn {
  prefs: TablePreferences
  setColumnVisibility: (key: string, visible: boolean) => void
  setColumnWidth: (key: string, width: number) => void
  setSortKey: (key: string | null) => void
  setSortDirection: (dir: SortDirection) => void
  setDensity: (density: TableDensity) => void
  setPageSize: (size: number) => void
  setFilter: (key: string, value: unknown) => void
  clearFilters: () => void
  resetPreferences: () => void
  /** Merge initial column config without overriding user preferences */
  initColumns: (keys: string[]) => void
}

/**
 * Persists all table display preferences per table ID.
 * User column choices, density, sorting, and filters survive page reloads.
 *
 * @example
 * const table = useTablePreferences("productos")
 * // table.prefs.columnVisibility, table.setSortKey("precio"), etc.
 */
export function useTablePreferences(tableId: string): UseTablePreferencesReturn {
  const storageKey = `table-prefs:${tableId}`
  const [prefs, setPrefs, resetPreferences] = usePersistentState<TablePreferences>(
    storageKey,
    DEFAULT_PREFERENCES,
  )

  const setColumnVisibility = useCallback(
    (key: string, visible: boolean) => {
      setPrefs((prev) => ({
        ...prev,
        columnVisibility: { ...prev.columnVisibility, [key]: visible },
      }))
    },
    [setPrefs],
  )

  const setColumnWidth = useCallback(
    (key: string, width: number) => {
      setPrefs((prev) => ({
        ...prev,
        columnWidths: { ...prev.columnWidths, [key]: width },
      }))
    },
    [setPrefs],
  )

  const setSortKey = useCallback(
    (key: string | null) => setPrefs((prev) => ({ ...prev, sortKey: key })),
    [setPrefs],
  )

  const setSortDirection = useCallback(
    (dir: SortDirection) => setPrefs((prev) => ({ ...prev, sortDirection: dir })),
    [setPrefs],
  )

  const setDensity = useCallback(
    (density: TableDensity) => setPrefs((prev) => ({ ...prev, density })),
    [setPrefs],
  )

  const setPageSize = useCallback(
    (size: number) => setPrefs((prev) => ({ ...prev, pageSize: size })),
    [setPrefs],
  )

  const setFilter = useCallback(
    (key: string, value: unknown) => {
      setPrefs((prev) => ({
        ...prev,
        filters: { ...prev.filters, [key]: value },
      }))
    },
    [setPrefs],
  )

  const clearFilters = useCallback(
    () => setPrefs((prev) => ({ ...prev, filters: {} })),
    [setPrefs],
  )

  const initColumns = useCallback(
    (keys: string[]) => {
      setPrefs((prev) => {
        // Only set order if user hasn't customized it yet
        if (prev.columnOrder.length > 0) return prev
        return {
          ...prev,
          columnOrder: keys,
          columnVisibility: keys.reduce(
            (acc, k) => ({ ...acc, [k]: prev.columnVisibility[k] ?? true }),
            {} as ColumnVisibility,
          ),
        }
      })
    },
    [setPrefs],
  )

  return useMemo(
    () => ({
      prefs,
      setColumnVisibility,
      setColumnWidth,
      setSortKey,
      setSortDirection,
      setDensity,
      setPageSize,
      setFilter,
      clearFilters,
      resetPreferences,
      initColumns,
    }),
    [
      prefs,
      setColumnVisibility,
      setColumnWidth,
      setSortKey,
      setSortDirection,
      setDensity,
      setPageSize,
      setFilter,
      clearFilters,
      resetPreferences,
      initColumns,
    ],
  )
}
