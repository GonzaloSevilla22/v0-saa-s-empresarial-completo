/**
 * presupuestos-modulo (tarea 5.5) — badge del estado de un presupuesto: los 5
 * estados más "Vencido" derivado (`isExpired`).
 *
 * Tokens semánticos (texto por rol sobre fondo tenue del mismo rol): el contraste AA lo
 * garantiza el remapeo de `theme.extend.textColor` y el gate
 * `token-contrast-aa`. Sin literales de paleta.
 */
import { Badge } from "@/components/ui/badge"
import { cn } from "@/lib/utils"
import { effectiveQuoteStatus, QUOTE_STATUS_LABELS } from "@/lib/quote-status"
import type { QuoteStatus } from "@/lib/quote-types"

const STATUS_CLASSES: Record<QuoteStatus, string> = {
  draft: "text-muted-foreground",
  sent: "border-primary/30 bg-primary/10 text-primary",
  accepted: "border-success/30 bg-success/10 text-success",
  expired: "border-warning/40 bg-warning/10 text-warning",
  rejected: "border-destructive/30 bg-destructive/10 text-destructive",
}

export interface QuoteStatusBadgeProps {
  status: QuoteStatus
  /** `draft|sent` con la validez pasada: se muestra "Vencido". */
  isExpired?: boolean
  className?: string
}

export function QuoteStatusBadge({ status, isExpired, className }: QuoteStatusBadgeProps) {
  const effective = effectiveQuoteStatus(status, isExpired)
  return (
    <Badge
      variant="outline"
      data-status={effective}
      className={cn("whitespace-nowrap", STATUS_CLASSES[effective], className)}
    >
      {QUOTE_STATUS_LABELS[effective]}
    </Badge>
  )
}
