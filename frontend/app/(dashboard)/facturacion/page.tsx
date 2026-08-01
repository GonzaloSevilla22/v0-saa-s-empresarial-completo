/**
 * /facturacion — Billing & subscription management page
 * C-10 subscription-ui-upgrade-flow
 *
 * Server Component: reads account + billing_events for the user.
 * Shows current plan, billing history, and cancellation option.
 */

import Link from "next/link"
import { redirect } from "next/navigation"
import { format } from "date-fns"
import { es } from "date-fns/locale"
import { createClient } from "@/lib/supabase/server"
import { BillingHistory } from "@/components/billing/BillingHistory"
import { CancelSubscriptionModal } from "@/components/billing/CancelSubscriptionModal"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { PLAN_DISPLAY_NAMES, getEffectivePlan } from "@/lib/plan-utils"
import type { Plan } from "@/lib/types"

export const metadata = {
  title: "Facturación — Aliadata",
}

const STATUS_LABELS: Record<string, string> = {
  active:     "Activo",
  trialing:   "Período de prueba",
  expired:    "Vencido",
  cancelled:  "Cancelado",
  cancelling: "Cancelación programada",
}

const STATUS_COLORS: Record<string, string> = {
  active:     "bg-emerald-100 text-emerald-700 border-emerald-200",
  trialing:   "bg-blue-100 text-blue-700 border-blue-200",
  expired:    "bg-slate-100 text-slate-600 border-slate-200",
  cancelled:  "bg-slate-100 text-slate-600 border-slate-200",
  cancelling: "bg-orange-100 text-orange-700 border-orange-200",
}

interface BillingEvent {
  id: string
  event_type: string
  from_plan: Plan | null
  to_plan: Plan | null
  amount: number | null
  created_at: string
}

// mp-real-subscriptions (D2bis, task 8.5): estado de la suscripción real
// (public.subscriptions). Etiquetas propias — es un dominio de estado
// DISTINTO de accounts.billing_status (STATUS_LABELS de arriba).
const SUBSCRIPTION_STATUS_LABELS: Record<string, string> = {
  pending:    "Esperando autorización",
  authorized: "Autorizada",
  paused:     "Pausada",
  cancelled:  "Cancelada",
  ambiguous:  "En verificación",
}

interface SubscriptionRow {
  plan: Plan
  status: string
  next_payment_date: string | null
  retry_state: string
  amount: number | null
  currency: string
}

export default async function FacturacionPage() {
  const supabase = createClient()

  // ── Auth ─────────────────────────────────────────────────────────────────────
  const { data: { user }, error: authError } = await supabase.auth.getUser()
  if (authError || !user) {
    redirect("/login")
  }

  // ── Account billing state ──────────────────────────────────────────────────
  const { data: memberRow } = await supabase
    .from("account_members")
    .select("account_id, accounts(billing_plan, billing_status, trial_plan, trial_expires_at, plan_expires_at, created_at, billing_exempt)")
    .eq("user_id", user.id)
    .maybeSingle()

  const accountData = memberRow?.accounts as unknown as {
    billing_plan: Plan
    billing_status: string
    trial_plan: Plan | null
    trial_expires_at: string | null
    plan_expires_at: string | null
    created_at: string
    billing_exempt: boolean | null
  } | null

  const billingPlan: Plan = accountData?.billing_plan ?? "gratis"
  const billingStatus = accountData?.billing_status ?? "active"
  const trialPlan = accountData?.trial_plan ?? null
  const trialExpiresAt = accountData?.trial_expires_at ?? null
  const planExpiresAt = accountData?.plan_expires_at ?? null
  const billingExempt = accountData?.billing_exempt ?? false

  // billing-pro-trial (D1/D6): getEffectivePlan NO lee billing_status — es
  // descriptivo, no autoritativo. billingStatus se conserva más abajo solo
  // para el badge de la UI de facturación (STATUS_LABELS/STATUS_COLORS).
  const effectivePlan = getEffectivePlan({
    billingPlan,
    trialPlan,
    trialExpiresAt,
    billingExempt,
  })

  // ── billing_events (last 20) ──────────────────────────────────────────────
  const { data: rawEvents } = await supabase
    .from("billing_events")
    .select("id, event_type, from_plan, to_plan, amount, created_at")
    .eq("user_id", user.id)
    .order("created_at", { ascending: false })
    .limit(20)

  const events: BillingEvent[] = (rawEvents ?? []).map((e) => ({
    id: e.id as string,
    event_type: e.event_type as string,
    from_plan: e.from_plan as Plan | null,
    to_plan: e.to_plan as Plan | null,
    amount: e.amount != null ? Number(e.amount) : null,
    created_at: e.created_at as string,
  }))

  // mp-real-subscriptions (D2bis, task 8.5): suscripción real viva, si
  // existe — se lee directo de `public.subscriptions` (RLS SELECT por
  // membresía de cuenta, PR2) en vez de llamar al backend, así esta
  // Server Component no necesita reenviar un JWT aparte. Con la palanca
  // `billing_subscriptions_enabled` apagada (default hoy en producción)
  // nunca hay filas todavía, así que esto degrada limpio a "no mostrar
  // nada" sin ninguna lógica de flag adicional acá.
  const accountId = memberRow?.account_id as string | undefined
  const { data: subscriptionRow } = accountId
    ? await supabase
        .from("subscriptions")
        .select("plan, status, next_payment_date, retry_state, amount, currency")
        .eq("account_id", accountId)
        .in("status", ["pending", "authorized"])
        .maybeSingle()
    : { data: null }

  const subscription = subscriptionRow as SubscriptionRow | null
  const subscriptionInRetry = subscription?.retry_state === "retrying"

  const isPaid = billingPlan !== "gratis"
  const isCancelling = billingStatus === "cancelling"
  const canCancel = isPaid && !isCancelling && billingStatus === "active"

  return (
    <div className="container max-w-4xl mx-auto px-4 py-8 space-y-10">
      <div>
        <h1 className="text-2xl font-bold text-foreground">Facturación</h1>
        <p className="text-muted-foreground mt-1">Gestioná tu suscripción y revisá tu historial de pagos.</p>
      </div>

      {/* Current plan card */}
      <section className="rounded-xl border border-border p-6 space-y-4">
        <h2 className="text-lg font-semibold text-foreground">Plan actual</h2>

        <div className="flex flex-wrap items-center gap-4">
          <div>
            <p className="text-3xl font-extrabold text-foreground">{PLAN_DISPLAY_NAMES[effectivePlan]}</p>
            {effectivePlan !== billingPlan && (
              <p className="text-xs text-muted-foreground mt-0.5">
                (trial — plan base: {PLAN_DISPLAY_NAMES[billingPlan]})
              </p>
            )}
          </div>
          <Badge className={`text-xs px-2.5 py-0.5 ${STATUS_COLORS[billingStatus] ?? ""}`}>
            {STATUS_LABELS[billingStatus] ?? billingStatus}
          </Badge>
        </div>

        {/* Trial/expiry info */}
        {trialExpiresAt && billingStatus === "trialing" && (
          <p className="text-sm text-muted-foreground">
            Tu período de prueba vence el{" "}
            <span className="font-medium text-foreground">
              {format(new Date(trialExpiresAt), "dd 'de' MMMM 'de' yyyy", { locale: es })}
            </span>
            .
          </p>
        )}

        {isCancelling && planExpiresAt && (
          <p className="text-sm text-orange-600 dark:text-orange-400">
            Tu suscripción fue cancelada. El plan {PLAN_DISPLAY_NAMES[billingPlan]} permanecerá activo hasta el{" "}
            <span className="font-medium">
              {format(new Date(planExpiresAt), "dd 'de' MMMM 'de' yyyy", { locale: es })}
            </span>
            .
          </p>
        )}

        {/* mp-real-subscriptions (D2bis, task 8.5): estado de la suscripción
            real — solo aparece si existe una fila viva en subscriptions
            (i.e. la palanca estuvo ON en algún momento para esta cuenta). */}
        {subscription && (
          <div className="rounded-lg border border-border bg-muted/40 p-4 space-y-1.5">
            <div className="flex flex-wrap items-center gap-2">
              <span className="text-sm font-medium text-foreground">Suscripción recurrente</span>
              <Badge variant="outline" className="text-xs px-2 py-0">
                {SUBSCRIPTION_STATUS_LABELS[subscription.status] ?? subscription.status}
              </Badge>
            </div>
            {subscription.next_payment_date && (
              <p className="text-sm text-muted-foreground">
                Próximo cobro:{" "}
                <span className="font-medium text-foreground">
                  {format(new Date(subscription.next_payment_date), "dd 'de' MMMM 'de' yyyy", { locale: es })}
                </span>
              </p>
            )}
            {subscriptionInRetry && (
              <p className="text-sm text-warning-foreground bg-warning/15 border border-warning/30 rounded-md px-3 py-2 mt-2">
                No pudimos procesar tu último cobro — MercadoPago está reintentando automáticamente.
                Tu acceso sigue activo mientras tanto.
              </p>
            )}
          </div>
        )}

        {/* Actions */}
        <div className="flex flex-wrap gap-3 pt-2">
          <Button asChild>
            <Link href="/planes">
              {isPaid ? "Cambiar plan" : "Ver planes disponibles"}
            </Link>
          </Button>
          {canCancel && <CancelSubscriptionModal currentPlan={billingPlan} />}
        </div>
      </section>

      {/* Billing history */}
      <section className="space-y-4">
        <h2 className="text-lg font-semibold text-foreground">Historial de facturación</h2>
        <BillingHistory events={events} />
      </section>
    </div>
  )
}
