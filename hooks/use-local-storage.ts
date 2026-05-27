"use client"

import { useState, useEffect, useCallback } from "react"

/**
 * Typed localStorage hook with SSR safety and JSON serialization.
 *
 * Usage:
 *   const [filters, setFilters] = useLocalStorage("filters:ventas", defaultFilters)
 *
 * Naming convention for keys:
 *   filters:{module}     → filter state per module
 *   columns:{table}      → column visibility per table
 *   recent:{entity}      → recently visited item IDs
 *   drafts:{formId}      → unsaved form state
 */
export function useLocalStorage<T>(key: string, initialValue: T) {
  const [storedValue, setStoredValue] = useState<T>(() => {
    if (typeof window === "undefined") return initialValue
    try {
      const item = window.localStorage.getItem(key)
      return item ? (JSON.parse(item) as T) : initialValue
    } catch {
      return initialValue
    }
  })

  useEffect(() => {
    if (typeof window === "undefined") return
    try {
      const item = window.localStorage.getItem(key)
      if (item !== null) {
        setStoredValue(JSON.parse(item) as T)
      }
    } catch {
      // localStorage unavailable (private mode, storage full) — use in-memory only
    }
  }, [key])

  const setValue = useCallback(
    (value: T | ((prev: T) => T)) => {
      try {
        const next = value instanceof Function ? value(storedValue) : value
        setStoredValue(next)
        if (typeof window !== "undefined") {
          window.localStorage.setItem(key, JSON.stringify(next))
        }
      } catch {
        // Silently fail if storage is full — UI state is non-critical
      }
    },
    [key, storedValue]
  )

  const removeValue = useCallback(() => {
    setStoredValue(initialValue)
    if (typeof window !== "undefined") {
      window.localStorage.removeItem(key)
    }
  }, [key, initialValue])

  return [storedValue, setValue, removeValue] as const
}
