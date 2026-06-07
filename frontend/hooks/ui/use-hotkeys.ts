"use client"

import { useEffect, useRef } from "react"

type ModifierKey = "ctrl" | "meta" | "shift" | "alt"
type HotkeyOptions = {
  preventDefault?: boolean
  /** Only fires when this element (or its children) has focus. Default: document */
  scope?: "document" | "window"
  /** Disable the hotkey without removing the listener */
  enabled?: boolean
}

/**
 * Registers a keyboard shortcut. Parses combos like "ctrl+k", "meta+shift+p".
 * Uses metaKey on Mac and ctrlKey on Windows/Linux automatically via "mod".
 *
 * @example
 * useHotkeys("mod+k", () => setCommandOpen(true))
 * useHotkeys("ctrl+shift+z", () => redo(), { preventDefault: true })
 * useHotkeys("escape", () => closeModal())
 */
export function useHotkeys(
  combo: string,
  handler: (e: KeyboardEvent) => void,
  options: HotkeyOptions = {},
): void {
  const { preventDefault = true, scope = "document", enabled = true } = options
  const handlerRef = useRef(handler)

  useEffect(() => {
    handlerRef.current = handler
  })

  useEffect(() => {
    if (!enabled) return

    const parts = combo.toLowerCase().split("+")
    const key = parts.at(-1)!
    const modifiers = parts.slice(0, -1) as ModifierKey[]

    const isMac = typeof navigator !== "undefined" && /mac/i.test(navigator.platform)

    const listener = (e: KeyboardEvent) => {
      const pressedKey = e.key.toLowerCase()
      if (pressedKey !== key) return

      const checks: Record<ModifierKey | "mod", boolean> = {
        ctrl: e.ctrlKey,
        meta: e.metaKey,
        shift: e.shiftKey,
        alt: e.altKey,
        mod: isMac ? e.metaKey : e.ctrlKey,
      }

      const allModifiersMatch = modifiers.every(
        (mod) => checks[mod as keyof typeof checks],
      )
      if (!allModifiersMatch) return

      if (preventDefault) e.preventDefault()
      handlerRef.current(e)
    }

    const target = scope === "window" ? window : document
    target.addEventListener("keydown", listener as EventListener)
    return () => target.removeEventListener("keydown", listener as EventListener)
  }, [combo, scope, enabled, preventDefault])
}
