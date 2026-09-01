"use client"

/**
 * qa-integral-modulos G1 (H1, D1): contexto que publica el nodo de contenido
 * del modal activo (DialogContent / SheetContent). `ui/popover.tsx` lo consume
 * para saber que vive dentro de un modal y neutralizar el bloqueo de scroll
 * del Dialog de Radix (react-remove-scroll cancela todo wheel/touchmove que
 * caiga fuera del shard del contenido del diálogo — y el popover, portalizado
 * a document.body, quedaba afuera).
 *
 * Fuera de un modal el contexto es `null` y ningún comportamiento cambia.
 */

import * as React from "react"

export const DialogContainerContext =
  React.createContext<HTMLElement | null>(null)

/**
 * Compone la ref reenviada del caller con el setState local que alimenta el
 * contexto. Extraído acá porque DialogContent y SheetContent lo repiten.
 */
export function useDialogContainer<T extends HTMLElement>(
  forwardedRef: React.ForwardedRef<T>,
): [T | null, (node: T | null) => void] {
  const [container, setContainer] = React.useState<T | null>(null)

  const composedRef = React.useCallback(
    (node: T | null) => {
      setContainer(node)
      if (typeof forwardedRef === "function") forwardedRef(node)
      else if (forwardedRef) forwardedRef.current = node
    },
    [forwardedRef],
  )

  return [container, composedRef]
}
