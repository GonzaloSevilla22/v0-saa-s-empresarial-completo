"use client"

import { Card, CardContent } from "@/components/ui/card"
import { FadeIn } from "@/components/motion/FadeIn"
import { cn } from "@/lib/utils"
import { Info } from "lucide-react"
import type { LucideIcon } from "lucide-react"
import { KpiExplainTrigger, type KpiExplanationProp } from "@/components/dashboard/KpiExplainTrigger"
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
  /** tablero-explicable (D4): con ella la tarjeta es un botón que abre
   *  «de dónde sale este número». Sin ella, el render es idéntico al de
   *  siempre (las tarjetas fuera del Tablero no cambian). */
  explanation?: KpiExplanationProp
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
  explanation,
}: KpiSummaryCardProps) {
  const card = (
    <Card className="border-border bg-card rounded-xl">
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
          {/* G12 (H27): el truncate cortaba "Feria 46% / S/C 45%" sin forma
              de leer el segundo valor — title expone el valor completo. */}
          <span
            className="text-xl font-bold text-card-foreground tracking-tight truncate"
            title={value}
          >
            {value}
          </span>
          <span className="flex items-center gap-1 text-xs text-muted-foreground">
            {label}
            {explanation && <Info aria-hidden="true" className="h-3 w-3 shrink-0 opacity-70" />}
          </span>
          {secondaryLine && (
            <span className="text-xs text-muted-foreground/80">{secondaryLine}</span>
          )}
        </div>
      </CardContent>
    </Card>
  )

  // v4-visual-3d-refresh Fase A (task 1.10): entrada animada tokenizada
  // (FadeIn, no MotionList — este card vive en un grid CSS y MotionList
  // agregaría un wrapper extra que dejaría de ser el hijo directo del
  // grid, rompiendo grid-cols-*/col-span-*). `className` (col-span de
  // KpiSummaryBlock) va acá, en el hijo directo del grid; Card conserva
  // su propio estilo fijo.
  return (
    <FadeIn className={className}>
      {explanation ? (
        <KpiExplainTrigger explanation={explanation} title={label} value={value} className="rounded-xl">
          {card}
        </KpiExplainTrigger>
      ) : (
        card
      )}
    </FadeIn>
  )
}
