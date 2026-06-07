"use client"

import { usePersistentState } from "./use-persistent-state"

/**
 * Thin wrapper over usePersistentState for cookie-backed state.
 * Use this for values that must be readable server-side (theme, locale, sidebar).
 *
 * @example
 * const [theme, setTheme] = useCookieState("ui:theme", "light")
 */
export function useCookieState<T>(
  key: string,
  initialValue: T,
  maxAge = 60 * 60 * 24 * 365,
): [T, (value: T | ((prev: T) => T)) => void, () => void] {
  return usePersistentState(key, initialValue, {
    backend: "cookie",
    cookieMaxAge: maxAge,
  })
}
