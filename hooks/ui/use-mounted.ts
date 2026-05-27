"use client"

import { useEffect, useState } from "react"

/**
 * Returns true only after hydration. Use to guard browser-only code
 * (localStorage, window, matchMedia) in components that also render server-side.
 *
 * Pattern: if (!mounted) return null  ← prevents hydration mismatch
 */
export function useMounted(): boolean {
  const [mounted, setMounted] = useState(false)
  useEffect(() => setMounted(true), [])
  return mounted
}
