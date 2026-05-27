"use client"

import { useEffect } from "react"
import { useTheme } from "next-themes"
import { setCookie, COOKIE_KEYS } from "@/lib/cookies"

/**
 * Invisible component mounted once in the root layout.
 * Syncs next-themes resolved theme → ui:theme cookie so the server
 * can read it on next load and render the correct theme without flash.
 */
export function ThemeSync() {
  const { resolvedTheme } = useTheme()

  useEffect(() => {
    if (resolvedTheme === "dark" || resolvedTheme === "light") {
      setCookie(COOKIE_KEYS.THEME, resolvedTheme)
    }
  }, [resolvedTheme])

  return null
}
