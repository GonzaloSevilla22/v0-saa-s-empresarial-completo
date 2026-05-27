"use client"

import { useCallback, useEffect, useRef } from "react"

interface UsePollingOptions {
  interval?: number
  enabled?: boolean
  /** Stop polling after this many attempts (0 = unlimited) */
  maxAttempts?: number
  onError?: (err: Error) => void
}

/**
 * Runs `callback` on an interval. Stops when `enabled` is false or when
 * the component unmounts. Uses refs to always call the latest version of
 * the callback without restarting the interval.
 *
 * @example
 * usePolling(() => refreshLowStock(), { interval: 30_000, enabled: isVisible })
 */
export function usePolling(
  callback: () => void | Promise<void>,
  options: UsePollingOptions = {},
): { stop: () => void } {
  const {
    interval = 30_000,
    enabled = true,
    maxAttempts = 0,
    onError,
  } = options

  const callbackRef = useRef(callback)
  const attemptRef = useRef(0)
  const intervalRef = useRef<ReturnType<typeof setInterval> | null>(null)

  useEffect(() => {
    callbackRef.current = callback
  })

  const stop = useCallback(() => {
    if (intervalRef.current) {
      clearInterval(intervalRef.current)
      intervalRef.current = null
    }
  }, [])

  useEffect(() => {
    if (!enabled) return stop()

    attemptRef.current = 0
    intervalRef.current = setInterval(async () => {
      try {
        await callbackRef.current()
        attemptRef.current++
        if (maxAttempts > 0 && attemptRef.current >= maxAttempts) stop()
      } catch (err) {
        onError?.(err instanceof Error ? err : new Error(String(err)))
      }
    }, interval)

    return stop
  }, [enabled, interval, maxAttempts, stop, onError])

  return { stop }
}
