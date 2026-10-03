/**
 * remitos-venta (tarea 5.3) — badge del estado de un remito: pendiente,
 * convertido en venta y anulado.
 *
 * Tokens semánticos (texto por rol sobre fondo tenue del mismo rol): el
 * contraste AA lo garantiza el remapeo de `theme.extend.textColor` y el gate
 * `token-contrast-aa`. Sin literales de paleta. Los rótulos salen de
 * `lib/delivery-note-status`, la misma fuente que usan las pestañas y el detalle.
 */
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import { DELIVERY_NOTE_STATUS_LABELS } from "@/lib/delivery-note-status"
import type { DeliveryNoteStatus } from "@/lib/delivery-note-types"

const STATUS_CLASSES: Record<DeliveryNoteStatus, string> = {
  issued: "border-warning/40 bg-warning/10 text-warning",
  converted: "border-success/30 bg-success/10 text-success",
  canceled: "border-destructive/30 bg-destructive/10 text-destructive",
}

export interface DeliveryNoteStatusBadgeProps {
  status: DeliveryNoteStatus
  className?: string
}

export function DeliveryNoteStatusBadge({ status, className }: DeliveryNoteStatusBadgeProps) {
  return (
    <Badge
      variant="outline"
      data-status={status}
      className={cn("whitespace-nowrap", STATUS_CLASSES[status], className)}
    >
      {DELIVERY_NOTE_STATUS_LABELS[status]}
    </Badge>
  )
}
