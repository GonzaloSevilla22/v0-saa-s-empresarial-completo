"use client"

import { useCallback, useState } from "react"

interface UseDrawerReturn<T = undefined> {
  isOpen: boolean
  data: T | null
  open: T extends undefined ? () => void : (data: T) => void
  close: () => void
  toggle: () => void
}

/**
 * Manages a drawer's open state, optionally carrying typed context data.
 * Use for edit drawers, detail panels, filter panels, etc.
 *
 * @example
 * // Simple drawer
 * const drawer = useDrawer()
 * <Button onClick={drawer.open}>Abrir</Button>
 * <Drawer open={drawer.isOpen} onClose={drawer.close} />
 *
 * // Drawer with data (edit panel)
 * const productDrawer = useDrawer<Product>()
 * <Button onClick={() => productDrawer.open(product)}>Editar</Button>
 * <EditDrawer open={productDrawer.isOpen} product={productDrawer.data} />
 */
export function useDrawer<T = undefined>(): UseDrawerReturn<T> {
  const [isOpen, setIsOpen] = useState(false)
  const [data, setData] = useState<T | null>(null)

  const open = useCallback((payload?: T) => {
    if (payload !== undefined) setData(payload as T)
    setIsOpen(true)
  }, []) as UseDrawerReturn<T>["open"]

  const close = useCallback(() => {
    setIsOpen(false)
    // Clear data after animation completes
    setTimeout(() => setData(null), 300)
  }, [])

  const toggle = useCallback(() => setIsOpen((prev) => !prev), [])

  return { isOpen, data, open, close, toggle }
}
