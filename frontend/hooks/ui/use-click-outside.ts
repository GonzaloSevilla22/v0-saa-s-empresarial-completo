"use client"

import { type RefObject, useEffect } from "react"

/**
 * Fires `handler` when a click/touch occurs outside the referenced element.
 * Supports multiple refs (e.g., trigger + panel both excluded).
 *
 * @example
 * const ref = useRef<HTMLDivElement>(null)
 * useClickOutside(ref, () => setOpen(false))
 */
export function useClickOutside<T extends HTMLElement>(
  ref: RefObject<T> | RefObject<T>[],
  handler: (event: MouseEvent | TouchEvent) => void,
): void {
  useEffect(() => {
    const refs = Array.isArray(ref) ? ref : [ref]

    const listener = (event: MouseEvent | TouchEvent) => {
      const target = event.target as Node
      const isInside = refs.some((r) => r.current?.contains(target))
      if (!isInside) handler(event)
    }

    document.addEventListener("mousedown", listener)
    document.addEventListener("touchstart", listener, { passive: true })

    return () => {
      document.removeEventListener("mousedown", listener)
      document.removeEventListener("touchstart", listener)
    }
  }, [ref, handler])
}
