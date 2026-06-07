"use client"

import { useState } from "react"
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
import type { Plan } from "@/lib/types"

interface CancelSubscriptionModalProps {
  currentPlan: Plan
}

/**
 * Confirmation modal for cancelling a paid subscription.
 * Calls POST /api/billing/cancel and refreshes the page on success.
 */
export function CancelSubscriptionModal({ currentPlan }: CancelSubscriptionModalProps) {
  const router = useRouter()
  const [loading, setLoading] = useState(false)

  // MVP: show estimated expiry as 30 days from today
  const estimatedExpiry = format(addDays(new Date(), 30), "dd 'de' MMMM 'de' yyyy", { locale: es })
  const planName = PLAN_DISPLAY_NAMES[currentPlan]

  async function handleConfirm() {
    setLoading(true)
    try {
      const res = await fetch("/api/billing/cancel", { method: "POST" })
      const data = await res.json() as { ok: boolean; error?: string; expiresAt?: string }

      if (!data.ok) {
        toast.error(data.error ?? "No se pudo cancelar la suscripción")
        return
      }

      toast.success("Suscripción cancelada. Tu plan permanecerá activo hasta la fecha de vencimiento.")
      router.refresh()
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Error inesperado"
      toast.error(message)
    } finally {
      setLoading(false)
    }
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
              <strong>{estimatedExpiry}</strong>. Después, tu cuenta pasará al plan{" "}
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
