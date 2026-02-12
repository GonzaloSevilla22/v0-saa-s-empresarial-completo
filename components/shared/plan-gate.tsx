"use client"

import { useAuth } from "@/contexts/auth-context"
import { Button } from "@/components/ui/button"
import { Crown } from "lucide-react"
import type { Plan } from "@/lib/types"

interface PlanGateProps {
  requiredPlan: Plan
  children: React.ReactNode
  featureName?: string
}

export function PlanGate({ requiredPlan, children, featureName = "esta funcion" }: PlanGateProps) {
  const { user, upgradePlan } = useAuth()

  if (user?.plan === "pro" || requiredPlan === "free") {
    return <>{children}</>
  }

  return (
    <div className="relative">
      <div className="pointer-events-none blur-sm opacity-50">{children}</div>
      <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 rounded-lg bg-background/80 backdrop-blur-sm">
        <div className="flex h-12 w-12 items-center justify-center rounded-full bg-yellow-500/10">
          <Crown className="h-6 w-6 text-yellow-500" />
        </div>
        <div className="text-center">
          <p className="text-sm font-medium text-foreground">Funcion Pro</p>
          <p className="text-xs text-muted-foreground mt-1">
            Actualiza tu plan para acceder a {featureName}
          </p>
        </div>
        <Button onClick={upgradePlan} size="sm" className="bg-yellow-500 text-yellow-950 hover:bg-yellow-400">
          <Crown className="h-3.5 w-3.5 mr-1" />
          Actualizar a Pro
        </Button>
      </div>
    </div>
  )
}
