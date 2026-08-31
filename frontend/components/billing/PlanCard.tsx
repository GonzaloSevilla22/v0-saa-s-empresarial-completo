"use client"

import Link from "next/link"
import { Crown, Check, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { PLAN_DISPLAY_NAMES, PLAN_HIERARCHY } from "@/lib/plan-utils"
import type { Plan, PlanLimits } from "@/lib/types"

interface PlanCardProps {
  plan: Plan
  currentPlan: Plan
  limits: PlanLimits
  onSelect: (plan: Plan) => void
  loading?: boolean
  /**
   * planes-suscribirse-plan-vigente (D3): disponibilidad de contratación a
   * NIVEL CUENTA (`!billingExempt && !haySuscripcionViva`) — NO depende de
   * `plan === currentPlan`. PlanCard la combina con `plan === 'gratis'`
   * (siempre no-contratable) para la disponibilidad final de ESTE tier.
   * Es la segunda entrada independiente que el requirement de
   * `specs/billing-ui/spec.md` ("Componente PlanCard reutilizable") exige:
   * el destacado (badge, de `currentPlan`) y la disponibilidad de
   * contratación NUNCA colapsan en una sola condición.
   */
  canContract: boolean
  /**
   * D4/OQ-5: tier de la suscripción viva de la cuenta, o `null`/`undefined`
   * si no hay ninguna. Gobierna, cuando `canContract` es `false` por causa
   * de una suscripción viva: el aviso "ya tenés una suscripción activa" en
   * la tarjeta que coincide, y el enlace a `/facturacion` (en vez de un
   * botón de compra) en las demás — restaura el requirement original de
   * `billing-ui` ("deshabilitado o linkea a /facturacion").
   */
  liveSubscriptionPlan?: Plan | null
  /** D5: línea de contexto (motivo del acceso); solo se renderiza cuando `plan === currentPlan`. */
  contextLine?: string | null
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

/**
 * planes-suscribirse-plan-vigente (D3/D4, task 3.6): derivación PURA del
 * estado del CTA, extraída de PlanCard para poder testearla sin renderizar
 * (y para que la precedencia de reglas —gratis > contratable > suscripción
 * viva propia > suscripción viva ajena > nada— viva en un solo lugar).
 *
 * "Suscribirme a X" cubre tanto el caso nuevo (tier === plan efectivo, sin
 * suscripción viva — OQ-1) como el downgrade contratable (D4: la acción es
 * literalmente contratar ese tier, "Cancelar y bajar" mentía). "Pasarme a
 * X" se conserva SOLO para el upgrade genuino — comportamiento correcto ya
 * cubierto por tests existentes que este change no edita (task 4.1).
 */
export type PlanCardCtaState =
  | { kind: "button"; label: string; disabled: boolean }
  | { kind: "link"; label: string; href: string }
  | { kind: "note"; label: string }
  | { kind: "none" }

export function resolvePlanCardCta(input: {
  plan: Plan
  displayName: string
  isCurrent: boolean
  isFree: boolean
  isUpgrade: boolean
  canContract: boolean
  liveSubscriptionPlan: Plan | null
}): PlanCardCtaState {
  const { plan, displayName, isCurrent, isFree, isUpgrade, canContract, liveSubscriptionPlan } = input

  if (isFree) {
    return {
      kind: "button",
      label: isCurrent ? "Plan actual" : `Cancelar y bajar a ${displayName}`,
      disabled: true,
    }
  }

  if (canContract) {
    return {
      kind: "button",
      label: isCurrent || !isUpgrade ? `Suscribirme a ${displayName}` : `Pasarme a ${displayName}`,
      disabled: false,
    }
  }

  if (liveSubscriptionPlan === plan) {
    return { kind: "note", label: "Ya tenés una suscripción activa de este plan." }
  }

  if (liveSubscriptionPlan !== null) {
    return { kind: "link", label: "Gestionar en Facturación", href: "/facturacion" }
  }

  return { kind: "none" }
}

export function PlanCard({
  plan,
  currentPlan,
  limits,
  onSelect,
  loading = false,
  canContract,
  liveSubscriptionPlan = null,
  contextLine = null,
}: PlanCardProps) {
  const displayName = PLAN_DISPLAY_NAMES[plan]
  const colors = PLAN_COLORS[plan]
  const features = PLAN_FEATURES[plan]

  const isCurrent = plan === currentPlan
  const isUpgrade = PLAN_HIERARCHY.indexOf(plan) > PLAN_HIERARCHY.indexOf(currentPlan)
  const isFree = plan === "gratis"

  const priceDisplay = isFree
    ? "Gratis"
    : `$${Number(limits.priceMonthly).toLocaleString("es-AR")}/mes`

  const ctaState = resolvePlanCardCta({
    plan,
    displayName,
    isCurrent,
    isFree,
    isUpgrade,
    canContract,
    liveSubscriptionPlan: liveSubscriptionPlan ?? null,
  })

  return (
    <div
      className={`relative flex h-full flex-col rounded-xl border-2 p-6 gap-4 ${colors.bg} ${colors.border} ${
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

      {/* Línea de contexto (D5): solo en la tarjeta del plan efectivo, y
          solo cuando hay un motivo que comunicar (cortesía / trial vigente
          / plan pago con vencimiento). Derivada de campos crudos por el
          caller — NO de getEffectivePlan (D6). */}
      {isCurrent && contextLine && (
        <p className="text-xs text-muted-foreground -mt-2">{contextLine}</p>
      )}

      {/* Features */}
      <ul className="flex flex-col gap-2 flex-1">
        {features.map((feat) => (
          <li key={feat} className="flex items-start gap-2 text-sm text-muted-foreground">
            <Check className="h-4 w-4 text-emerald-500 shrink-0 mt-0.5" />
            {feat}
          </li>
        ))}
      </ul>

      {/* CTA — estado derivado por resolvePlanCardCta (D3/D4) */}
      {ctaState.kind === "button" && (
        <Button
          onClick={() => onSelect(plan)}
          disabled={ctaState.disabled || loading}
          className={`w-full mt-2 ${ctaState.disabled ? "opacity-60 cursor-not-allowed" : ""} ${colors.button}`}
          variant="ghost"
        >
          {/* G10 (H21c): mientras el alta está en vuelo, el botón lo DICE —
              antes solo se deshabilitaba sin señal, invitando al reintento. */}
          {loading ? (
            <>
              <Loader2 className="mr-2 h-4 w-4 animate-spin" />
              Procesando…
            </>
          ) : (
            ctaState.label
          )}
        </Button>
      )}

      {ctaState.kind === "link" && (
        <Button asChild variant="outline" className="w-full mt-2">
          <Link href={ctaState.href}>{ctaState.label}</Link>
        </Button>
      )}

      {ctaState.kind === "note" && (
        <p className="w-full mt-2 rounded-md border border-border bg-muted/40 px-3 py-2 text-center text-sm text-muted-foreground">
          {ctaState.label}
        </p>
      )}
    </div>
  )
}
