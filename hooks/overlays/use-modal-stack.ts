"use client"

import { useCallback, useState } from "react"

interface ModalEntry<T = unknown> {
  id: string
  data?: T
}

interface UseModalStackReturn {
  stack: ModalEntry[]
  push: (id: string, data?: unknown) => void
  pop: () => void
  clear: () => void
  isOpen: (id: string) => boolean
  getData: <T>(id: string) => T | undefined
  top: ModalEntry | null
  depth: number
}

/**
 * Manages a stack of modals for complex flows (e.g., confirm inside an edit modal).
 * Each modal has a unique ID and optional typed data.
 *
 * @example
 * const modals = useModalStack()
 *
 * // Open an edit modal
 * modals.push("edit-product", product)
 *
 * // Inside the modal, open a confirm modal
 * modals.push("confirm-delete")
 *
 * // Read data
 * const product = modals.getData<Product>("edit-product")
 *
 * // Close current (top) modal
 * modals.pop()
 *
 * // Close all
 * modals.clear()
 */
export function useModalStack(): UseModalStackReturn {
  const [stack, setStack] = useState<ModalEntry[]>([])

  const push = useCallback((id: string, data?: unknown) => {
    setStack((prev) => [...prev, { id, data }])
  }, [])

  const pop = useCallback(() => {
    setStack((prev) => prev.slice(0, -1))
  }, [])

  const clear = useCallback(() => setStack([]), [])

  const isOpen = useCallback(
    (id: string) => stack.some((entry) => entry.id === id),
    [stack],
  )

  const getData = useCallback(
    <T>(id: string): T | undefined => {
      return stack.find((entry) => entry.id === id)?.data as T | undefined
    },
    [stack],
  )

  return {
    stack,
    push,
    pop,
    clear,
    isOpen,
    getData,
    top: stack.at(-1) ?? null,
    depth: stack.length,
  }
}
