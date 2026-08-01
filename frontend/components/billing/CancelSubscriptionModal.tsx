"use client"

import { useEffect, useState } from "react"
import { useRouter } from "next/navigation"
import { format, addDays } from "date-fns"
import { es } from "date-fns/locale"
import { toast } from "sonner"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { PLAN_DISPLAY_NAMES } from "@/lib/plan-utils"
import { cancelSubscription, getSubscriptionStatus } from "@/lib/api/subscriptions-client"
import type { Plan } from "@/lib/types"

interface CancelSubscriptionModalProps {
  currentPlan: Plan
}

/**
 * Confirmation modal for cancelling a paid subscription.
 *
 * mp-real-subscriptions (D2bis, task 8.3/8.4): cuando hay una suscripción
 * real (palanca `billing_subscriptions_enabled` ON), muestra la fecha del
 * período REALMENTE pagado (next_payment_date del backend) — no un
 * intervalo calculado en el navegador — y cancela vía
 * `DELETE /payments/subscriptions`. Con la palanca apagada (default hoy en
 * producción) o sin suscripción real todavía, degrada limpio al flujo
 * legacy (`POST /api/billing/cancel`) con la estimación de 30 días que ya
 * existía — no-regresión.
 */
export function CancelSubscriptionModal({ currentPlan }: CancelSubscriptionModalProps) {
  const router = useRouter()
  const [loading, setLoading] = useState(false)
  const [realExpiresAt, setRealExpiresAt] = useState<string | null>(null)
  const [hasRealSubscription, setHasRealSubscription] = useState(false)

  useEffect(() => {
    let cancelled = false
    getSubscriptionStatus()
      .then((result) => {
        if (cancelled || !result.enabled || !result.data) return
        setHasRealSubscription(true)
        setRealExpiresAt(result.data.next_payment_date)
      })
      .catch(() => {
        // Best-effort: si falla, se degrada al estimado legacy sin romper el modal.
      })
    return () => {
      cancelled = true
    }
  }, [])

  // MVP legacy: estimación de 30 días — solo se usa si no hay suscripción real.
  const legacyEstimatedExpiry = format(addDays(new Date(), 30), "dd 'de' MMMM 'de' yyyy", { locale: es })
  const expiryDisplay =
    hasRealSubscription && realExpiresAt
      ? format(new Date(realExpiresAt), "dd 'de' MMMM 'de' yyyy", { locale: es })
      : legacyEstimatedExpiry
  const planName = PLAN_DISPLAY_NAMES[currentPlan]

  async function handleConfirm() {
    setLoading(true)
    try {
      if (hasRealSubscription) {
        const result = await cancelSubscription()
        if (!result.enabled) {
          // Se apagó la palanca entre el fetch inicial y la confirmación —
          // caso borde raro, degradar al legacy en vez de fallar.
          await handleLegacyCancel()
          return
        }
        toast.success("Suscripción cancelada. Tu plan permanecerá activo hasta la fecha de vencimiento.")
        router.refresh()
        return
      }
      await handleLegacyCancel()
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Error inesperado"
      toast.error(message)
    } finally {
      setLoading(false)
    }
  }

  async function handleLegacyCancel() {
    const res = await fetch("/api/billing/cancel", { method: "POST" })
    const data = (await res.json()) as { ok: boolean; error?: string; expiresAt?: string }

    if (!data.ok) {
      toast.error(data.error ?? "No se pudo cancelar la suscripción")
      return
    }

    toast.success("Suscripción cancelada. Tu plan permanecerá activo hasta la fecha de vencimiento.")
    router.refresh()
  }

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button variant="outline" className="border-destructive text-destructive hover:bg-destructive/10">
          Cancelar suscripción
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>¿Cancelar el plan {planName}?</AlertDialogTitle>
          <AlertDialogDescription className="space-y-2">
            <span className="block">
              Tu plan <strong>{planName}</strong> seguirá activo hasta el{" "}
              <strong>{expiryDisplay}</strong>. Después, tu cuenta pasará al plan{" "}
              <strong>Gratis</strong> automáticamente.
            </span>
            <span className="block text-muted-foreground text-xs">
              Podés reactivar tu suscripción en cualquier momento antes de esa fecha.
            </span>
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel>Volver</AlertDialogCancel>
          <AlertDialogAction
            onClick={handleConfirm}
            disabled={loading}
            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
          >
            {loading ? "Cancelando..." : "Confirmar cancelación"}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
