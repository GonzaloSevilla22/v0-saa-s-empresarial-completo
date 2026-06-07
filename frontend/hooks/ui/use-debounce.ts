"use client"

import { useEffect, useRef, useState } from "react"

/**
 * Debounces a value — only updates after `delay` ms of inactivity.
 * Safe to use with any serializable type.
 *
 * @example
 * const debouncedSearch = useDebounce(searchInput, 300)
 * useEffect(() => fetchResults(debouncedSearch), [debouncedSearch])
 */
export function useDebounce<T>(value: T, delay = 300): T {
  const [debounced, setDebounced] = useState<T>(value)

  useEffect(() => {
    const id = setTimeout(() => setDebounced(value), delay)
    return () => clearTimeout(id)
  }, [value, delay])

  return debounced
}

/**
 * Debounces a callback — returns a stable ref-based function that only
 * fires after `delay` ms of inactivity. The callback always captures the
 * latest closure via ref, so stale-closure bugs are impossible.
 */
export function useDebouncedCallback<T extends (...args: never[]) => unknown>(
  callback: T,
  delay = 300,
): (...args: Parameters<T>) => void {
  const callbackRef = useRef(callback)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Keep ref current without triggering re-renders
  useEffect(() => {
    callbackRef.current = callback
  })

  return (...args: Parameters<T>) => {
    if (timerRef.current) clearTimeout(timerRef.current)
    timerRef.current = setTimeout(() => {
      callbackRef.current(...args)
    }, delay)
  }
}
