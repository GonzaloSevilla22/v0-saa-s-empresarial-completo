/**
 * /planes — Plan selection & upgrade page
 * C-10 subscription-ui-upgrade-flow
 *
 * Server Component: reads plan_limits and current user plan from the DB.
 * Passes data to PlanComparison (Client Component) which handles the MP redirect.
 */

import { redirect } from "next/navigation"
import { createClient } from "@/lib/supabase/server"
import { PlanComparison } from "@/components/billing/PlanComparison"
import { EnterprisePlanCard } from "@/components/shared/EnterprisePlanCard"
import { PLAN_DISPLAY_NAMES } from "@/lib/plan-utils"
import { getEffectivePlan } from "@/lib/plan-utils"
import { aliadataWhatsAppUrl, ALIADATA_WHATSAPP_MESSAGE_EMPRESA } from "@/lib/aliadata-contact"
import type { Plan, PlanLimits } from "@/lib/types"

export const metadata = {
  title: "Planes y precios — Aliadata",
}

export default async function PlanesPage() {
  const supabase = createClient()

  // ── Auth ─────────────────────────────────────────────────────────────────────
  const { data: { user }, error: authError } = await supabase.auth.getUser()
  if (authError || !user) {
    redirect("/login")
  }

  // ── Current account billing state ─────────────────────────────────────────
  const { data: memberRow } = await supabase
    .from("account_members")
    .select("account_id, accounts(billing_plan, billing_status, trial_plan, trial_expires_at, billing_exempt)")
    .eq("user_id", user.id)
    .maybeSingle()

  const accountData = memberRow?.accounts as unknown as {
    billing_plan: Plan
    billing_status: string
    trial_plan: Plan | null
    trial_expires_at: string | null
    billing_exempt: boolean | null
  } | null

  const billingPlan: Plan = accountData?.billing_plan ?? "gratis"
  const trialPlan = accountData?.trial_plan ?? null
  const trialExpiresAt = accountData?.trial_expires_at ?? null
  const billingExempt = accountData?.billing_exempt ?? false

  // billing-pro-trial (D1/D6): getEffectivePlan NO lee billing_status.
  const effectivePlan = getEffectivePlan({
    billingPlan,
    trialPlan,
    trialExpiresAt,
    billingExempt,
  })

  // ── plan_limits ───────────────────────────────────────────────────────────
  const { data: rawPlans, error: plansError } = await supabase
    .from("plan_limits")
    .select("*")
    .order("price_monthly", { ascending: true })

  if (plansError || !rawPlans) {
    console.error("[/planes] Failed to fetch plan_limits:", plansError)
    throw new Error("No se pudieron cargar los planes. Intentá de nuevo.")
  }

  // Map snake_case DB columns to camelCase PlanLimits interface
  const plans: PlanLimits[] = rawPlans.map((row) => ({
    plan: row.plan as Plan,
    priceMonthly: Number(row.price_monthly),
    maxUsers: row.max_users,
    maxProducts: row.max_products,
    maxClients: row.max_clients,
    maxSuppliers: row.max_suppliers,
    maxOperationsPerMonth: row.max_operations_per_month,
    historyDays: row.history_days,
    maxExportsPerMonth: row.max_exports_per_month,
    maxAiQueriesPerMonth: row.max_ai_queries_per_month,
    maxAiAdvicePerMonth: row.max_ai_advice_per_month,
    maxBranches: row.max_branches,
    hasProductProfitability: row.has_product_profitability,
    hasComparativeReports: row.has_comparative_reports,
    hasPriceSuggestion: row.has_price_suggestion,
    hasBranchesModule: row.has_branches_module,
    hasMonthlyAnalysis: row.has_monthly_analysis,
    internalRoles: row.internal_roles,
  }))

  const currentPlanName = PLAN_DISPLAY_NAMES[effectivePlan]

  // Tier Empresa (plan-empresa-contacto, D5): el número se resuelve acá,
  // igual que en app/page.tsx — /planes ya es Server Component y ya hace
  // getUser(), así que sumar esta lectura no cambia el contrato de la ruta.
  // Sin número válido, `null` y el bloque no se monta (D6).
  const enterpriseWhatsAppUrl = aliadataWhatsAppUrl(
    process.env.ALIADATA_WHATSAPP_PHONE,
    ALIADATA_WHATSAPP_MESSAGE_EMPRESA,
  )

  return (
    <div className="container max-w-6xl mx-auto px-4 py-8 space-y-8">
      {/* Header */}
      <div className="text-center space-y-2">
        <h1 className="text-3xl font-bold text-foreground">Planes y precios</h1>
        <p className="text-muted-foreground">
          Actualmente estás en el plan{" "}
          <span className="font-semibold text-foreground">{currentPlanName}</span>.
          Elegí el plan que mejor se adapte a tu negocio.
        </p>
      </div>

      {/* Comparison grid */}
      <PlanComparison plans={plans} currentPlan={effectivePlan} />

      {/* Tier Empresa (plan-empresa-contacto, D3): HERMANO del comparativo,
          nunca dentro — PlanComparison no se toca. Sin enterpriseWhatsAppUrl
          (número no configurado) no se renderiza nada (D6). */}
      {enterpriseWhatsAppUrl && (
        <div data-testid="planes-enterprise-block">
          <EnterprisePlanCard whatsappUrl={enterpriseWhatsAppUrl} variant="app" />
        </div>
      )}

      {/* Footer note */}
      <p className="text-center text-xs text-muted-foreground">
        Todos los precios son en pesos argentinos (ARS) e incluyen IVA.
        El cobro se procesa a través de MercadoPago.
      </p>
    </div>
  )
}
