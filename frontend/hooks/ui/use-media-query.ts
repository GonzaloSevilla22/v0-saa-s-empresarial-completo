"use client"

import { useEffect, useState } from "react"

/**
 * Reactive media query hook. SSR-safe (returns false until mounted).
 *
 * @example
 * const isDesktop = useMediaQuery("(min-width: 1024px)")
 * const prefersReducedMotion = useMediaQuery("(prefers-reduced-motion: reduce)")
 * const isDark = useMediaQuery("(prefers-color-scheme: dark)")
 */
export function useMediaQuery(query: string): boolean {
  const [matches, setMatches] = useState(false)

  useEffect(() => {
    const mql = window.matchMedia(query)
    setMatches(mql.matches)

    const handler = (e: MediaQueryListEvent) => setMatches(e.matches)
    mql.addEventListener("change", handler)
    return () => mql.removeEventListener("change", handler)
  }, [query])

  return matches
}

// Pre-built breakpoint hooks matching Tailwind defaults
export const useIsDesktop = () => useMediaQuery("(min-width: 1024px)")
export const useIsTablet = () => useMediaQuery("(min-width: 768px) and (max-width: 1023px)")
export const useIsMobile = () => useMediaQuery("(max-width: 767px)")
