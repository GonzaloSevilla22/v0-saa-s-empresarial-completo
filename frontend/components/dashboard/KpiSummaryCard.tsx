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
}

// Hex del spec §5; fondo semi-transparente del mismo color.
const TONE_CLASSES: Record<KpiBadgeTone, string> = {
  green: "text-[#34D399] bg-[#34D399]/15",
  red: "text-[#F87171] bg-[#F87171]/15",
  yellow: "text-[#FBBF24] bg-[#FBBF24]/15",
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
        </div>
      </CardContent>
    </Card>
  )
}
