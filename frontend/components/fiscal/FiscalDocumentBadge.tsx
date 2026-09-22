"use client"

/**
 * C-27 v21-fiscal-profile — FiscalDocumentBadge.
 *
 * Badge con estado de un comprobante fiscal (`pending_cae | authorized | rejected`).
 * Se suscribe a cambios Realtime en `fiscal_documents` para el documento dado
 * y actualiza el badge automáticamente cuando el relay cambia `pending_cae → authorized`.
 *
 * Design ref: D5 (async CAE machine), D6 (relay idempotente), DEC-16 (Realtime en Supabase).
 *
 * Usage:
 *   <FiscalDocumentBadge documentId="uuid" initialStatus="pending_cae" />
 */

import { useEffect, useState } from "react"
import { createClient } from "@/lib/supabase/client"
import { Badge } from "@/components/ui/badge"
import { AlertTriangle, Loader2 } from "lucide-react"

// ── Types ─────────────────────────────────────────────────────────────────────

export type FiscalDocumentStatus = "pending_cae" | "authorized" | "rejected"

interface FiscalDocumentBadgeProps {
  documentId: string
  initialStatus: FiscalDocumentStatus
  /** Si es true, muestra el estado en texto largo. Default: false (compact). */
  verbose?: boolean
  /**
   * fiscal-emision-segura (M-4, red team 2026-09-22): true si el comprobante
   * está CONGELADO (G4 — un FECAESolicitar salió y su resultado nunca se
   * confirmó). Un congelado sigue reportando `status='pending_cae'` — sin
   * esta bandera, el badge lo mostraría "En trámite" para siempre y nadie
   * sabría que necesita revisión manual en ARCA. Es el estado inicial (page
   * load); el badge también lo detecta en vivo por Realtime más abajo, así
   * que el caller puede omitirlo si su endpoint todavía no lo trae.
   */
  initialFrozen?: boolean
}

// ── Config ────────────────────────────────────────────────────────────────────

const STATUS_CONFIG: Record<
  FiscalDocumentStatus,
  { label: string; labelVerbose: string; className: string }
> = {
  pending_cae: {
    label:        "En trámite",
    labelVerbose: "En trámite (esperando CAE)",
    className:    "bg-yellow-500/10 text-yellow-600 border-yellow-500/30",
  },
  authorized: {
    label:        "Autorizado",
    labelVerbose: "Autorizado por AFIP",
    className:    "bg-green-500/10 text-green-500 border-green-500/30",
  },
  rejected: {
    label:        "Rechazado",
    labelVerbose: "Rechazado por AFIP",
    className:    "bg-red-500/10 text-red-500 border-red-500/30",
  },
}

// ── Component ─────────────────────────────────────────────────────────────────

export function FiscalDocumentBadge({
  documentId,
  initialStatus,
  verbose = false,
  initialFrozen = false,
}: FiscalDocumentBadgeProps) {
  const [status, setStatus] = useState<FiscalDocumentStatus>(initialStatus)
  const [frozen, setFrozen] = useState<boolean>(initialFrozen)

  useEffect(() => {
    // Reset cuando el documento cambia (ej. la tabla re-renderiza otra fila)
    setStatus(initialStatus)
    setFrozen(initialFrozen)
  }, [documentId, initialStatus, initialFrozen])

  useEffect(() => {
    // Solo suscribirse si el estado es aún transitorio (pending_cae).
    // Si ya está en estado final (authorized | rejected), no hace falta Realtime.
    if (status !== "pending_cae") return

    const supabase = createClient()

    const channel = supabase
      .channel(`fiscal_document_status_${documentId}`)
      .on(
        "postgres_changes",
        {
          event:  "UPDATE",
          schema: "public",
          table:  "fiscal_documents",
          filter: `id=eq.${documentId}`,
        },
        (payload) => {
          const newStatus = payload.new?.status as FiscalDocumentStatus | undefined
          if (newStatus && newStatus !== status) {
            setStatus(newStatus)
          }
          // fiscal-emision-segura (M-4, red team 2026-09-22): el mismo UPDATE
          // que congela (G4) trae `cae_submit_unconfirmed_at` en el payload —
          // reutiliza la suscripción que ya existía, sin un canal aparte.
          if (payload.new?.cae_submit_unconfirmed_at) {
            setFrozen(true)
          }
        },
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [documentId, status])

  // Un congelado sigue siendo status='pending_cae' — la bandera manda por
  // encima del status para no mostrar "En trámite" indefinidamente.
  if (frozen) {
    return (
      <Badge
        variant="outline"
        className="inline-flex items-center gap-1 text-xs bg-red-500/10 text-red-600 border-red-500/30 dark:text-red-400"
        title="El envío a ARCA no se confirmó (pudo haber sido aprobado sin registro local). Requiere verificación manual en ARCA antes de reintentar."
      >
        <AlertTriangle className="h-3 w-3" />
        {verbose ? "Congelado — requiere revisión manual" : "Congelado"}
      </Badge>
    )
  }

  const config = STATUS_CONFIG[status]

  return (
    <Badge variant="outline" className={`inline-flex items-center gap-1 text-xs ${config.className}`}>
      {status === "pending_cae" && (
        <Loader2 className="h-3 w-3 animate-spin" />
      )}
      {verbose ? config.labelVerbose : config.label}
    </Badge>
  )
}
