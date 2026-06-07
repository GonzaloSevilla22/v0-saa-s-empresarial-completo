"use client"

import Link from "next/link"
import { usePlanGate } from "@/hooks/auth/use-plan-gate"
import { PLAN_DISPLAY_NAMES } from "@/lib/plan-utils"
import { Button } from "@/components/ui/button"
import { Crown } from "lucide-react"
import type { Plan } from "@/lib/types"

interface PlanGateProps {
  requiredPlan: Plan
  children: React.ReactNode
  featureName?: string
}

/**
 * Gates children behind a minimum plan. If the user's effective plan
 * (trial-aware) meets requiredPlan, children render normally. Otherwise a
 * blurred overlay with an upgrade CTA is shown.
 */
export function PlanGate({ requiredPlan, children, featureName = "esta función" }: PlanGateProps) {
  const { hasAccess } = usePlanGate(requiredPlan)

  if (hasAccess) {
    return <>{children}</>
  }

  const requiredName = PLAN_DISPLAY_NAMES[requiredPlan]

  return (
    <div className="relative">
      <div className="pointer-events-none blur-sm opacity-50">{children}</div>
      <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 rounded-lg bg-background/80 backdrop-blur-sm">
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-yellow-500/10">
          <Crown className="h-6 w-6 text-yellow-500" />
        </div>
        <div className="text-center">
          <p className="text-sm font-medium text-foreground">Requiere plan {requiredName}</p>
          <p className="text-xs text-muted-foreground mt-1">
            Actualizá tu plan para acceder a {featureName}
          </p>
        </div>
        <Button asChild size="sm" className="bg-yellow-500 text-yellow-950 hover:bg-yellow-400">
          <Link href="/planes">
            <Crown className="h-3.5 w-3.5 mr-1" />
            Ver planes
          </Link>
        </Button>
      </div>
    </div>
  )
}
