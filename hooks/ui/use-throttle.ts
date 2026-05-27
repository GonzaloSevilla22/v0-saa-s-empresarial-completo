"use client"

import { useEffect, useRef, useState } from "react"

/**
 * Throttles a value — updates at most once per `interval` ms.
 * Useful for scroll/resize handlers and live search with cheap queries.
 */
export function useThrottle<T>(value: T, interval = 200): T {
  const [throttled, setThrottled] = useState<T>(value)
  const lastUpdated = useRef<number>(0)

  useEffect(() => {
    const now = Date.now()
    const remaining = interval - (now - lastUpdated.current)

    if (remaining <= 0) {
      lastUpdated.current = now
      setThrottled(value)
    } else {
      const id = setTimeout(() => {
        lastUpdated.current = Date.now()
        setThrottled(value)
      }, remaining)
      return () => clearTimeout(id)
    }
  }, [value, interval])

  return throttled
}
