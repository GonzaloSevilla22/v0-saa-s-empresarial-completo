"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { toast } from "sonner"
import { PlanCard } from "@/components/billing/PlanCard"
import type { Plan, PlanLimits } from "@/lib/types"

interface PlanComparisonProps {
  plans: PlanLimits[]
  currentPlan: Plan
}

/**
 * Renders a 4-column plan comparison grid using PlanCard.
 * Handles the CTA click: POST to /api/billing/preferences and redirect to initPoint.
 * Used in app/(dashboard)/planes/page.tsx (rendered as Server Component that
 * passes data; this Client Component owns the interactivity).
 */
export function PlanComparison({ plans, currentPlan }: PlanComparisonProps) {
  const router = useRouter()
  const [loadingPlan, setLoadingPlan] = useState<Plan | null>(null)

  const planOrder: Plan[] = ["gratis", "inicial", "avanzado", "pro"]
  const sortedPlans = planOrder
    .map((p) => plans.find((pl) => pl.plan === p))
    .filter(Boolean) as PlanLimits[]

  async function handleSelect(plan: Plan) {
    if (plan === currentPlan || plan === "gratis") return

    setLoadingPlan(plan)
    try {
      const res = await fetch("/api/billing/preferences", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ plan }),
      })

      const data = await res.json() as { ok: boolean; initPoint?: string; error?: string }

      if (!data.ok || !data.initPoint) {
        toast.error(data.error ?? "Error al crear la preferencia de pago")
        return
      }

      // Redirect to MercadoPago Checkout Pro
      router.push(data.initPoint)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Error inesperado"
      toast.error(message)
    } finally {
      setLoadingPlan(null)
    }
  }

  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-6">
      {sortedPlans.map((planLimits) => (
        <PlanCard
          key={planLimits.plan}
          plan={planLimits.plan}
          currentPlan={currentPlan}
          limits={planLimits}
          onSelect={handleSelect}
          loading={loadingPlan === planLimits.plan}
        />
      ))}
    </div>
  )
}
