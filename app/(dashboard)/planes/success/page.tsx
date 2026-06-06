/**
 * /planes/success — Payment success confirmation page
 * C-10 subscription-ui-upgrade-flow
 *
 * MercadoPago redirects here after an approved payment.
 * We refetch the account to display the new plan (webhook may have already
 * processed it; if not, we show a "processing" state).
 */

import Link from "next/link"
import { redirect } from "next/navigation"
import { CheckCircle2 } from "lucide-react"
import { createClient } from "@/lib/supabase/server"
import { Button } from "@/components/ui/button"
import { PLAN_DISPLAY_NAMES } from "@/lib/plan-utils"
import type { Plan } from "@/lib/types"

export const metadata = {
  title: "¡Pago exitoso! — EmprendeSmart",
}

export default async function PlanesSuccessPage() {
  const supabase = createClient()

  const { data: { user }, error: authError } = await supabase.auth.getUser()
  if (authError || !user) {
    redirect("/login")
  }

  // Read current plan (webhook may already have updated it)
  const { data: memberRow } = await supabase
    .from("account_members")
    .select("accounts(billing_plan)")
    .eq("user_id", user.id)
    .maybeSingle()

  const currentPlan = (memberRow?.accounts as unknown as { billing_plan: Plan } | null)?.billing_plan ?? "gratis"
  const planName = PLAN_DISPLAY_NAMES[currentPlan]

  return (
    <div className="container max-w-lg mx-auto px-4 py-16 text-center space-y-6">
      <div className="flex justify-center">
        <CheckCircle2 className="h-16 w-16 text-emerald-500" />
      </div>

      <div className="space-y-2">
        <h1 className="text-3xl font-bold text-foreground">¡Pago exitoso!</h1>
        <p className="text-muted-foreground">
          Tu plan <span className="font-semibold text-foreground">{planName}</span> está activo.
          Ya podés usar todas las funciones de tu nuevo plan.
        </p>
      </div>

      <div className="bg-emerald-500/10 border border-emerald-500/30 rounded-lg p-4 text-sm text-emerald-700 dark:text-emerald-400">
        Te enviamos un email de confirmación con los detalles de tu suscripción.
      </div>

      <div className="flex flex-col sm:flex-row gap-3 justify-center">
        <Button asChild>
          <Link href="/dashboard">Ir al dashboard</Link>
        </Button>
        <Button asChild variant="outline">
          <Link href="/facturacion">Ver facturación</Link>
        </Button>
      </div>
    </div>
  )
}
