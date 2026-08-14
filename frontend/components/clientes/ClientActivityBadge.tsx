"use client"

/**
 * Indicador de actividad comercial del cliente — client-activity
 * §"Señalización de actividad en la lista de clientes".
 *
 * `status` viaja ya resuelto desde el backend (backend/core/client_activity.py):
 * este componente sólo mapea estado → texto + tokens semánticos, nunca
 * recalcula umbrales. El estado nunca se comunica sólo por color — cada
 * variante lleva su propio texto legible.
 */

import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "@/lib/utils"
import type { ClientActivityStatus } from "@/hooks/data/use-client-activity"

const clientActivityBadgeVariants = cva(
  "inline-flex items-center rounded-full border px-2.5 py-0.5 text-xs font-semibold whitespace-nowrap",
  {
    variants: {
      status: {
        frecuente:    "border-transparent bg-success/15 text-success",
        activo:       "border-transparent bg-secondary text-secondary-foreground",
        inactivo:     "border-transparent bg-warning/15 text-warning",
        sin_compras:  "border-border bg-transparent text-muted-foreground",
      },
    },
  },
)

const STATUS_LABEL: Record<ClientActivityStatus, string> = {
  frecuente:    "Frecuente",
  activo:       "Activo",
  inactivo:     "Inactivo",
  sin_compras:  "Sin compras",
}

export interface ClientActivityBadgeProps
  extends VariantProps<typeof clientActivityBadgeVariants> {
  status:     ClientActivityStatus
  className?: string
}

export function ClientActivityBadge({ status, className }: ClientActivityBadgeProps) {
  return (
    <span className={cn(clientActivityBadgeVariants({ status }), className)}>
      {STATUS_LABEL[status]}
    </span>
  )
}
