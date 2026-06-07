"use client"

import { Crown, Check } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { PLAN_DISPLAY_NAMES, PLAN_HIERARCHY, planHasAccess } from "@/lib/plan-utils"
import type { Plan, PlanLimits } from "@/lib/types"

interface PlanCardProps {
  plan: Plan
  currentPlan: Plan
  limits: PlanLimits
  onSelect: (plan: Plan) => void
  loading?: boolean
}

const PLAN_FEATURES: Record<Plan, string[]> = {
  gratis: [
    "1 usuario",
    "100 productos",
    "100 operaciones/mes",
    "30 días de historial",
    "5 consultas IA/mes",
  ],
  inicial: [
    "2 usuarios",
    "500 productos",
    "500 operaciones/mes",
    "365 días de historial",
    "30 consultas IA/mes",
    "3 exportaciones/mes",
  ],
  avanzado: [
    "5 usuarios",
    "1.500 productos",
    "2.000 operaciones/mes",
    "730 días de historial",
    "120 consultas IA/mes",
    "Rentabilidad de productos",
    "Reportes comparativos",
    "Sugerencia de precios",
    "15 exportaciones/mes",
  ],
  pro: [
    "10 usuarios",
    "5.000 productos",
    "6.000 operaciones/mes",
    "1.825 días de historial",
    "300 consultas IA/mes",
    "Todo lo de Avanzado",
    "Módulo de sucursales",
    "Análisis mensual avanzado",
    "50 exportaciones/mes",
  ],
}

const PLAN_COLORS: Record<Plan, { bg: string; border: string; badge: string; button: string }> = {
  gratis:   { bg: "bg-card", border: "border-border", badge: "bg-slate-100 text-slate-700", button: "bg-slate-200 text-slate-700 hover:bg-slate-300" },
  inicial:  { bg: "bg-card", border: "border-border", badge: "bg-blue-100 text-blue-700", button: "bg-blue-500 text-white hover:bg-blue-600" },
  avanzado: { bg: "bg-card", border: "border-yellow-500/50", badge: "bg-yellow-100 text-yellow-700", button: "bg-yellow-500 text-yellow-950 hover:bg-yellow-400" },
  pro:      { bg: "bg-card", border: "border-emerald-500/50", badge: "bg-emerald-100 text-emerald-700", button: "bg-emerald-600 text-white hover:bg-emerald-700" },
}

export function PlanCard({ plan, currentPlan, limits, onSelect, loading = false }: PlanCardProps) {
  const displayName = PLAN_DISPLAY_NAMES[plan]
  const colors = PLAN_COLORS[plan]
  const features = PLAN_FEATURES[plan]

  const isCurrent = plan === currentPlan
  const isDowngrade = PLAN_HIERARCHY.indexOf(plan) < PLAN_HIERARCHY.indexOf(currentPlan)
  const isUpgrade = PLAN_HIERARCHY.indexOf(plan) > PLAN_HIERARCHY.indexOf(currentPlan)
  const isFree = plan === "gratis"

  const priceDisplay = isFree
    ? "Gratis"
    : `$${Number(limits.priceMonthly).toLocaleString("es-AR")}/mes`

  const ctaLabel = isCurrent
    ? "Plan actual"
    : isUpgrade
      ? `Pasarme a ${displayName}`
      : isDowngrade
        ? `Cancelar y bajar a ${displayName}`
        : "Seleccionar"

  return (
    <div
      className={`relative flex flex-col rounded-xl border-2 p-6 gap-4 ${colors.bg} ${colors.border} ${
        isCurrent ? "ring-2 ring-primary ring-offset-2" : ""
      }`}
    >
      {isCurrent && (
        <Badge className="absolute -top-3 left-1/2 -translate-x-1/2 bg-primary text-primary-foreground text-xs px-3 py-0.5">
          Plan actual
        </Badge>
      )}

      {/* Header */}
      <div className="flex items-start justify-between gap-2">
        <div>
          <h3 className="text-lg font-bold text-foreground">{displayName}</h3>
          <p className="text-2xl font-extrabold text-foreground mt-1">{priceDisplay}</p>
        </div>
        {(plan === "avanzado" || plan === "pro") && (
          <Crown className="h-6 w-6 text-yellow-500 shrink-0 mt-1" />
        )}
      </div>

      {/* Features */}
      <ul className="flex flex-col gap-2 flex-1">
        {features.map((feat) => (
          <li key={feat} className="flex items-start gap-2 text-sm text-muted-foreground">
            <Check className="h-4 w-4 text-emerald-500 shrink-0 mt-0.5" />
            {feat}
          </li>
        ))}
      </ul>

      {/* CTA */}
      <Button
        onClick={() => onSelect(plan)}
        disabled={isCurrent || loading || isFree}
        className={`w-full mt-2 ${isCurrent || isFree ? "opacity-60 cursor-not-allowed" : ""} ${
          isCurrent || isFree ? colors.button : colors.button
        }`}
        variant="ghost"
      >
        {ctaLabel}
      </Button>
    </div>
  )
}
