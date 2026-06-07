"use client"

import { useEffect, useRef } from "react"

/**
 * Returns the value from the previous render.
 * Useful for detecting direction of change (asc→desc, old stock vs new stock).
 */
export function usePrevious<T>(value: T): T | undefined {
  const ref = useRef<T | undefined>(undefined)
  useEffect(() => {
    ref.current = value
  })
  return ref.current
}
