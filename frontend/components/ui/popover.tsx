'use client'

import * as React from 'react'
import * as PopoverPrimitive from '@radix-ui/react-popover'

import { cn } from '@/lib/utils'
import { DialogContainerContext } from '@/components/ui/dialog-container-context'

/**
 * qa-integral-modulos G1 (H1, el bug del PO — D1/R1, plan C promovido a plan A):
 *
 * Dentro de un Dialog/Sheet, react-remove-scroll (montado por el Dialog de
 * Radix) cancela todo wheel/touchmove que caiga fuera del shard del contenido
 * del modal — y el popover, portalizado a document.body, quedaba afuera: la
 * lista no se movía un píxel (informe H1).
 *
 * La variante elegida por el design (portal con `container` al nodo del
 * DialogContent) se implementó y se verificó en el arnés: el `transform` del
 * DialogContent lo vuelve containing block del popper `fixed` y su
 * `overflow-y-auto` lo recorta en el borde del diálogo (R1 confirmado
 * empíricamente — captura en el run del 2026-08-31; el camino del Sheet sí
 * funcionaba). Por eso se promueve el plan C que el propio design deja
 * pre-autorizado: registrar el popper como shard del bloqueo de scroll.
 *
 * Mecanismo: `modal` en el Root de Radix Popover — su camino modal monta su
 * PROPIO RemoveScroll con el popper como shard (API pública de Radix, sin
 * parchear nada); al ser el lock más reciente, los gestos sobre la lista dejan
 * de cancelarse. Se activa SOLO cuando DialogContainerContext dice que el
 * popover vive dentro de un modal: fuera de modales el contexto es null y el
 * comportamiento es EXACTAMENTE el de siempre (portal a body, no-modal) —
 * el radio de explosión que descartó la opción 1 del informe no existe acá.
 */
const Popover = ({
  modal,
  ...props
}: React.ComponentProps<typeof PopoverPrimitive.Root>) => {
  const insideModal = React.useContext(DialogContainerContext) !== null
  return <PopoverPrimitive.Root modal={modal ?? insideModal} {...props} />
}

const PopoverTrigger = PopoverPrimitive.Trigger

const PopoverContent = React.forwardRef<
  React.ElementRef<typeof PopoverPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof PopoverPrimitive.Content>
>(({ className, align = 'center', sideOffset = 4, ...props }, ref) => (
  <PopoverPrimitive.Portal>
    <PopoverPrimitive.Content
      ref={ref}
      align={align}
      sideOffset={sideOffset}
      className={cn(
        'z-50 w-72 rounded-md border bg-popover p-4 text-popover-foreground shadow-md outline-none data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95 data-[side=bottom]:slide-in-from-top-2 data-[side=left]:slide-in-from-right-2 data-[side=right]:slide-in-from-left-2 data-[side=top]:slide-in-from-bottom-2',
        className,
      )}
      {...props}
    />
  </PopoverPrimitive.Portal>
))
PopoverContent.displayName = PopoverPrimitive.Content.displayName

export { Popover, PopoverTrigger, PopoverContent }
