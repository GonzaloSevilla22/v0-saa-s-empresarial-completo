"use client"

import { Card, CardContent } from "@/components/ui/card"
import { cn } from "@/lib/utils"
import type { LucideIcon } from "lucide-react"
import type { KpiBadgeTone } from "@/lib/kpi-format"

// ─── Props ────────────────────────────────────────────────────────────────────

interface KpiSummaryCardProps {
  /** Etiqueta del KPI (debajo del valor, muted). */
  label: string
  /** Valor principal ya formateado ("—" cuando no hay dato del período). */
  value: string
  /** Texto del badge de variación ("▲ +12%", "23 productos", "—"). */
  badge: string
  /** Color del badge según la lógica de polaridad (spec §5). */
  tone: KpiBadgeTone
  icon: LucideIcon
  /** Clase de color del ícono (esquina superior izquierda). */
  iconColor?: string
  className?: string
  /** v3-reporting-invariants (D8): línea secundaria opcional bajo el label
   *  (p.ej. "Cobrado: $8.000" en Ganancia Neta cuando percibido ≠ devengado). */
  secondaryLine?: string | null
}

// v4-visual-3d-refresh Fase A (task 1.9): los hex literales del spec §5
// (equivalentes a emerald-400/red-400/amber-400) migrados a tokens
// semánticos (frontend/docs/design-tokens.md), ya cubiertos por
// success/destructive/warning. Fondo semi-transparente del mismo color.
const TONE_CLASSES: Record<KpiBadgeTone, string> = {
  green: "text-success bg-success/15",
  red: "text-destructive bg-destructive/15",
  yellow: "text-warning bg-warning/15",
}

// ─── Component ────────────────────────────────────────────────────────────────

export function KpiSummaryCard({
  label,
  value,
  badge,
  tone,
  icon: Icon,
  iconColor = "text-primary",
  className,
  secondaryLine = null,
}: KpiSummaryCardProps) {
  return (
    <Card className={cn("border-border bg-card rounded-xl", className)}>
      <CardContent className="p-4">
        <div className="flex items-start justify-between gap-2">
          <div className={cn("flex h-8 w-8 shrink-0 items-center justify-center rounded-lg bg-primary/10", iconColor)}>
            <Icon className="h-4 w-4" />
          </div>
          <span
            data-testid="kpi-badge"
            data-tone={tone}
            className={cn(
              "rounded-md px-1.5 py-0.5 text-[11px] font-medium whitespace-nowrap",
              TONE_CLASSES[tone],
            )}
          >
            {badge}
          </span>
        </div>
        <div className="mt-3 flex flex-col gap-0.5 min-w-0">
          <span className="text-xl font-bold text-card-foreground tracking-tight truncate">
            {value}
          </span>
          <span className="text-xs text-muted-foreground">{label}</span>
          {secondaryLine && (
            <span className="text-xs text-muted-foreground/80">{secondaryLine}</span>
          )}
        </div>
      </CardContent>
    </Card>
  )
}
