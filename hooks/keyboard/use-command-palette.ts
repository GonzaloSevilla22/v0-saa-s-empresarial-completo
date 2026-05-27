"use client"

import { useCallback, useEffect, useMemo, useRef, useState } from "react"
import { useHotkeys } from "../ui/use-hotkeys"

export interface CommandItem {
  id: string
  label: string
  description?: string
  icon?: string
  group?: string
  keywords?: string[]
  action: () => void | Promise<void>
  /** Hide from results but keep registered */
  hidden?: boolean
  /** Show a keyboard shortcut badge */
  shortcut?: string
}

interface UseCommandPaletteOptions {
  /** Open/close hotkey. Default: "mod+k" */
  hotkey?: string
}

interface UseCommandPaletteReturn {
  isOpen: boolean
  query: string
  results: CommandItem[]
  selectedIndex: number
  open: () => void
  close: () => void
  setQuery: (q: string) => void
  register: (commands: CommandItem[]) => () => void
  executeSelected: () => void
  selectNext: () => void
  selectPrev: () => void
}

function scoreCommand(item: CommandItem, query: string): number {
  const q = query.toLowerCase()
  const label = item.label.toLowerCase()
  const keywords = item.keywords?.join(" ").toLowerCase() ?? ""
  const desc = item.description?.toLowerCase() ?? ""

  if (label === q) return 100
  if (label.startsWith(q)) return 80
  if (label.includes(q)) return 60
  if (keywords.includes(q)) return 40
  if (desc.includes(q)) return 20
  return 0
}

/**
 * Full command palette (⌘K) implementation. Register commands from any component,
 * search them, navigate with arrow keys, execute with Enter.
 *
 * @example
 * // At app level:
 * const palette = useCommandPalette()
 *
 * // Register commands in a module:
 * useEffect(() => {
 *   return palette.register([
 *     { id: "nav-productos", label: "Ir a Productos", action: () => router.push("/productos"), icon: "📦" },
 *     { id: "new-product", label: "Nuevo Producto", action: () => setDialogOpen(true), shortcut: "N" },
 *   ])
 * }, [])
 *
 * // Render:
 * <CommandPaletteDialog {...palette} />
 */
export function useCommandPalette(
  options: UseCommandPaletteOptions = {},
): UseCommandPaletteReturn {
  const { hotkey = "mod+k" } = options

  const [isOpen, setIsOpen] = useState(false)
  const [query, setQuery] = useState("")
  const [selectedIndex, setSelectedIndex] = useState(0)
  const [registeredCommands, setRegisteredCommands] = useState<CommandItem[]>([])
  const cleanupRef = useRef<Map<symbol, CommandItem[]>>(new Map())

  const open = useCallback(() => {
    setIsOpen(true)
    setQuery("")
    setSelectedIndex(0)
  }, [])

  const close = useCallback(() => {
    setIsOpen(false)
    setQuery("")
  }, [])

  useHotkeys(hotkey, open, { enabled: !isOpen })
  useHotkeys("escape", close, { enabled: isOpen })

  const results = useMemo(() => {
    const visible = registeredCommands.filter((c) => !c.hidden)
    if (!query.trim()) return visible

    return visible
      .map((cmd) => ({ cmd, score: scoreCommand(cmd, query.trim()) }))
      .filter(({ score }) => score > 0)
      .sort((a, b) => b.score - a.score)
      .map(({ cmd }) => cmd)
  }, [registeredCommands, query])

  // Keep selectedIndex in bounds when results change
  useEffect(() => {
    setSelectedIndex((prev) => Math.min(prev, Math.max(0, results.length - 1)))
  }, [results.length])

  const selectNext = useCallback(() => {
    setSelectedIndex((prev) => (prev + 1) % Math.max(results.length, 1))
  }, [results.length])

  const selectPrev = useCallback(() => {
    setSelectedIndex((prev) =>
      prev <= 0 ? Math.max(results.length - 1, 0) : prev - 1,
    )
  }, [results.length])

  const executeSelected = useCallback(async () => {
    const cmd = results[selectedIndex]
    if (!cmd) return
    close()
    await cmd.action()
  }, [results, selectedIndex, close])

  /**
   * Register commands and return a cleanup function.
   * Call inside useEffect so commands are removed on unmount.
   */
  const register = useCallback((commands: CommandItem[]): (() => void) => {
    const token = Symbol()
    cleanupRef.current.set(token, commands)
    setRegisteredCommands((prev) => {
      const existingIds = new Set(prev.map((c) => c.id))
      const newCmds = commands.filter((c) => !existingIds.has(c.id))
      return [...prev, ...newCmds]
    })
    return () => {
      const toRemove = cleanupRef.current.get(token)
      if (!toRemove) return
      const ids = new Set(toRemove.map((c) => c.id))
      setRegisteredCommands((prev) => prev.filter((c) => !ids.has(c.id)))
      cleanupRef.current.delete(token)
    }
  }, [])

  return {
    isOpen,
    query,
    results,
    selectedIndex,
    open,
    close,
    setQuery,
    register,
    executeSelected,
    selectNext,
    selectPrev,
  }
}
