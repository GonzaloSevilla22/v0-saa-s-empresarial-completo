"use client"

import { useState } from "react"
import { useRouter } from "next/navigation"
import { toast } from "sonner"
import { PlanCard } from "@/components/billing/PlanCard"
import {
  createSubscription,
  SubscriptionConflictError,
  type SubscriptionPlan,
} from "@/lib/api/subscriptions-client"
import type { Plan, PlanLimits } from "@/lib/types"

interface PlanComparisonProps {
  plans: PlanLimits[]
  currentPlan: Plan
  /**
   * planes-suscribirse-plan-vigente (D3, group 6): cuenta exenta de
   * facturación (`accounts.billing_exempt`) — suprime todo CTA de
   * contratación en los cuatro tiers, no solo en el plan efectivo.
   */
  billingExempt?: boolean
  /**
   * D3/D4: tier de la suscripción viva de la cuenta (`public.subscriptions`,
   * `status IN ('pending','authorized')`), o `null` si no hay ninguna. El
   * backend rechaza CUALQUIER contratación con 409 mientras exista una fila
   * viva, sin importar qué tier se pida (`find_live_subscription` no filtra
   * por plan) — por eso este flag bloquea la contratación en TODOS los
   * tiers, no solo en el que coincide.
   */
  liveSubscriptionPlan?: Plan | null
  /** D5: línea de contexto del plan efectivo (motivo del acceso), derivada de campos crudos por el caller. */
  currentPlanContextLine?: string | null
  /** OQ-2: canal de contacto para el aviso de exención (reusa `aliadataWhatsAppUrl`, sin inventar uno nuevo). */
  contactUrl?: string | null
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
export function PlanComparison({
  plans,
  currentPlan,
  billingExempt = false,
  liveSubscriptionPlan = null,
  currentPlanContextLine = null,
  contactUrl = null,
}: PlanComparisonProps) {
  const router = useRouter()
  const [loadingPlan, setLoadingPlan] = useState<Plan | null>(null)

  const planOrder: Plan[] = ["gratis", "inicial", "avanzado", "pro"]
  const sortedPlans = planOrder
    .map((p) => plans.find((pl) => pl.plan === p))
    .filter(Boolean) as PlanLimits[]

  // D3: regla única de contratación, a nivel cuenta — NO depende de qué
  // tier se esté evaluando (más allá de excluir 'gratis', que PlanCard
  // aplica internamente). Una suscripción viva bloquea TODOS los tiers
  // porque el backend rechaza con 409 sin importar el plan pedido.
  const canContract = !billingExempt && liveSubscriptionPlan === null

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
    // D3: el plan efectivo YA NO se excluye acá — una cuenta sin
    // suscripción viva puede contratar el tier que ya usa (incidente
    // 29-08). `canContract` ya descarta exención y suscripción viva.
    if (plan === "gratis" || !canContract) return

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
      if (err instanceof SubscriptionConflictError) {
        // D8: carrera real (checkout completado en otra pestaña mientras
        // esta pantalla seguía abierta) — mensaje propio, NUNCA el detail
        // crudo del backend, y refresh para que el Server Component
        // recalcule con la suscripción ya viva y la pantalla se acomode sola.
        toast.error("Ya tenés una suscripción activa — actualizamos la pantalla.")
        router.refresh()
      } else {
        const message = err instanceof Error ? err.message : "Error inesperado"
        toast.error(message)
      }
    } finally {
      setLoadingPlan(null)
    }
  }

  return (
    <div className="space-y-4">
      {billingExempt && (
        <div
          data-testid="billing-exempt-notice"
          className="rounded-lg border border-border bg-muted/40 p-4 text-sm text-muted-foreground"
        >
          <p>
            Tu acceso está otorgado sin cargo — no vas a ver botones de contratación en esta
            pantalla.
          </p>
          {contactUrl && (
            <a href={contactUrl} target="_blank" rel="noreferrer" className="font-medium text-foreground underline underline-offset-2">
              ¿Querés empezar a pagar un plan? Escribinos.
            </a>
          )}
        </div>
      )}
      <div className="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-4 gap-6">
        {sortedPlans.map((planLimits) => (
          <PlanCard
            key={planLimits.plan}
            plan={planLimits.plan}
            currentPlan={currentPlan}
            limits={planLimits}
            onSelect={handleSelect}
            loading={loadingPlan === planLimits.plan}
            canContract={canContract}
            liveSubscriptionPlan={liveSubscriptionPlan}
            contextLine={planLimits.plan === currentPlan ? currentPlanContextLine : null}
          />
        ))}
      </div>
    </div>
  )
}
