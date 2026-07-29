"use client"

import { useAuth } from "@/contexts/auth-context"
import { AlertTriangle, X } from "lucide-react"
import Link from "next/link"
import { useState } from "react"

/**
 * TrialBanner — shows "Te quedan N días de prueba" when the user has an active
 * trial that expires in the future.
 *
 * Rules:
 * - Only renders when billing_status = 'trialing' AND trial_expires_at is set
 *   AND the expiry is in the future (already-expired trials: billing_status
 *   becomes 'expired' via expire_trials(), so this guard is a safety net).
 * - Beta users (trial_expires_at = null) never see the banner.
 * - Dismissible for the current browser session (does NOT write to DB).
 */
export function TrialBanner() {
  const { user } = useAuth()
  const [dismissed, setDismissed] = useState(false)

  if (dismissed) return null
  if (!user) return null
  if (user.billingStatus !== "trialing") return null
  if (!user.trialExpiresAt) return null

  const expiresAt = new Date(user.trialExpiresAt)
  const now = new Date()
  if (expiresAt <= now) return null

  const diffMs = expiresAt.getTime() - now.getTime()
  const diffDays = Math.ceil(diffMs / (1000 * 60 * 60 * 24))

  const isUrgent = diffDays <= 3
  const label =
    diffDays === 1
      ? "Te queda 1 día de prueba del plan Avanzado"
      : `Te quedan ${diffDays} días de prueba del plan Avanzado`

  return (
    <div
      role="alert"
      className={[
        // v4-visual-3d-refresh Fase A (task 1.9): red-50/amber-50 + shade
        // scale (200/500/600/700/800) migrados a destructive/warning con
        // opacidad (fondo/borde) — el cuerpo del mensaje queda en
        // text-foreground (no text-destructive/text-warning) para no perder
        // el contraste AA que las variantes 800 garantizaban sobre el fondo
        // claro; el ícono y el link sí usan el tono semántico pleno, igual
        // que en el original (500/700).
        "flex items-center justify-between gap-3 rounded-lg px-4 py-2.5 text-sm",
        isUrgent
          ? "bg-destructive/10 border border-destructive/25 text-foreground"
          : "bg-warning/10 border border-warning/25 text-foreground",
      ].join(" ")}
    >
      <div className="flex items-center gap-2 min-w-0">
        <AlertTriangle
          className={["h-4 w-4 shrink-0", isUrgent ? "text-destructive" : "text-warning"].join(" ")}
          aria-hidden="true"
        />
        <span className="truncate">{label}</span>
      </div>

      <div className="flex items-center gap-3 shrink-0">
        <Link
          href="/planes"
          className={[
            "font-medium underline underline-offset-2 hover:no-underline whitespace-nowrap",
            isUrgent ? "text-destructive" : "text-warning",
          ].join(" ")}
        >
          Ver planes
        </Link>
        <button
          onClick={() => setDismissed(true)}
          aria-label="Cerrar aviso de prueba"
          className={[
            "rounded p-0.5 hover:bg-black/10 transition-colors",
            isUrgent ? "text-destructive" : "text-warning",
          ].join(" ")}
        >
          <X className="h-4 w-4" aria-hidden="true" />
        </button>
      </div>
    </div>
  )
}
