"use client"

import { useEffect, useRef, type RefObject } from "react"

/**
 * Devuelve el foco a `target` cuando un diálogo controlado por estado se cierra.
 *
 * Radix devuelve el foco al `Trigger` del diálogo; un diálogo que se abre por
 * estado (sin `Trigger`, como el de rechazar o el de eliminar un presupuesto)
 * deja el foco en el `<body>` y quien navega con teclado vuelve al principio de
 * la página. El `setTimeout` corre DESPUÉS de la limpieza de Radix, que ya
 * desmontó su trampa de foco.
 */
export function useRestoreFocus(open: boolean, target: RefObject<HTMLElement | null>): void {
  const wasOpen = useRef(false)

  useEffect(() => {
    if (open) {
      wasOpen.current = true
      return
    }
    if (!wasOpen.current) return
    wasOpen.current = false
    const id = window.setTimeout(() => target.current?.focus(), 0)
    return () => window.clearTimeout(id)
  }, [open, target])
}
