"use client"

import { useCallback, useMemo, useState } from "react"

interface UseTableSelectionReturn<T> {
  selected: Set<string>
  isSelected: (id: string) => boolean
  isAllSelected: boolean
  isPartiallySelected: boolean
  toggle: (id: string) => void
  toggleAll: (items: T[]) => void
  select: (id: string) => void
  deselect: (id: string) => void
  selectMany: (ids: string[]) => void
  clear: () => void
  selectedItems: T[]
  count: number
}

/**
 * Manages multi-row selection for tables. Handles select-all, partial selection
 * (for the indeterminate checkbox state), and single row toggles.
 *
 * @example
 * const selection = useTableSelection(products, (p) => p.id)
 *
 * <Checkbox
 *   checked={selection.isAllSelected}
 *   indeterminate={selection.isPartiallySelected}
 *   onCheckedChange={() => selection.toggleAll(products)}
 * />
 *
 * // Bulk delete
 * await deleteMany(selection.selectedItems)
 * selection.clear()
 */
export function useTableSelection<T>(
  allItems: T[],
  getId: (item: T) => string,
): UseTableSelectionReturn<T> {
  const [selected, setSelected] = useState<Set<string>>(new Set())

  const isSelected = useCallback(
    (id: string) => selected.has(id),
    [selected],
  )

  const toggle = useCallback((id: string) => {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }, [])

  const toggleAll = useCallback(
    (items: T[]) => {
      const allIds = items.map(getId)
      const allSelected = allIds.every((id) => selected.has(id))
      if (allSelected) {
        setSelected((prev) => {
          const next = new Set(prev)
          allIds.forEach((id) => next.delete(id))
          return next
        })
      } else {
        setSelected((prev) => new Set([...prev, ...allIds]))
      }
    },
    [getId, selected],
  )

  const select = useCallback(
    (id: string) => setSelected((prev) => new Set([...prev, id])),
    [],
  )

  const deselect = useCallback((id: string) => {
    setSelected((prev) => {
      const next = new Set(prev)
      next.delete(id)
      return next
    })
  }, [])

  const selectMany = useCallback(
    (ids: string[]) =>
      setSelected((prev) => new Set([...prev, ...ids])),
    [],
  )

  const clear = useCallback(() => setSelected(new Set()), [])

  const allVisibleIds = useMemo(() => allItems.map(getId), [allItems, getId])
  const isAllSelected =
    allVisibleIds.length > 0 && allVisibleIds.every((id) => selected.has(id))
  const isPartiallySelected =
    !isAllSelected && allVisibleIds.some((id) => selected.has(id))

  const selectedItems = useMemo(
    () => allItems.filter((item) => selected.has(getId(item))),
    [allItems, selected, getId],
  )

  return {
    selected,
    isSelected,
    isAllSelected,
    isPartiallySelected,
    toggle,
    toggleAll,
    select,
    deselect,
    selectMany,
    clear,
    selectedItems,
    count: selected.size,
  }
}
