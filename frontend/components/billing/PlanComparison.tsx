"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { toast } from "sonner"
import { PlanCard } from "@/components/billing/PlanCard"
import { createSubscription, type SubscriptionPlan } from "@/lib/api/subscriptions-client"
import type { Plan, PlanLimits } from "@/lib/types"

interface PlanComparisonProps {
  plans: PlanLimits[]
  currentPlan: Plan
}

function isSubscriptionPlan(plan: Plan): plan is SubscriptionPlan {
  return plan === "inicial" || plan === "avanzado" || plan === "pro"
}

/**
 * Renders a 4-column plan comparison grid using PlanCard.
 *
 * mp-real-subscriptions (D2bis, task 8.1/8.2): el CTA intenta PRIMERO el
 * flujo nuevo de suscripciones reales (POST al backend, redirige al
 * init_point del plan — MercadoPago crea el preapproval cuando el pagador
 * completa el checkout, ver design.md D2bis). Si el backend responde que
 * la palanca `billing_subscriptions_enabled` está apagada (default hoy en
 * producción), cae SIN fricción al flujo legacy de pago único
 * (`/api/billing/preferences`) — no-regresión mientras la palanca siga OFF.
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

  async function handleLegacyPreference(plan: Plan) {
    const res = await fetch("/api/billing/preferences", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ plan }),
    })

    const data = (await res.json()) as { ok: boolean; initPoint?: string; error?: string }

    if (!data.ok || !data.initPoint) {
      toast.error(data.error ?? "Error al crear la preferencia de pago")
      return
    }

    router.push(data.initPoint)
  }

  async function handleSelect(plan: Plan) {
    if (plan === currentPlan || plan === "gratis") return

    setLoadingPlan(plan)
    try {
      if (isSubscriptionPlan(plan)) {
        const result = await createSubscription(plan)
        if (result.enabled) {
          router.push(result.data.init_point)
          return
        }
        // Palanca apagada — degradación limpia al flujo legacy, sin avisar
        // al usuario de un cambio que no existe desde su perspectiva.
      }
      await handleLegacyPreference(plan)
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
