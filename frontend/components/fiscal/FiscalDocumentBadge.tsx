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
import { Loader2 } from "lucide-react"

// ── Types ─────────────────────────────────────────────────────────────────────

export type FiscalDocumentStatus = "pending_cae" | "authorized" | "rejected"

interface FiscalDocumentBadgeProps {
  documentId: string
  initialStatus: FiscalDocumentStatus
  /** Si es true, muestra el estado en texto largo. Default: false (compact). */
  verbose?: boolean
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
}: FiscalDocumentBadgeProps) {
  const [status, setStatus] = useState<FiscalDocumentStatus>(initialStatus)

  useEffect(() => {
    // Reset cuando el documento cambia (ej. la tabla re-renderiza otra fila)
    setStatus(initialStatus)
  }, [documentId, initialStatus])

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
        },
      )
      .subscribe()

    return () => {
      supabase.removeChannel(channel)
    }
  }, [documentId, status])

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
