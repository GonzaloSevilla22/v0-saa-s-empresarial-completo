"use client"

/**
 * factura-fiscal-imprimible (D10) — FiscalInvoiceSummary.
 *
 * El bloque del comprobante fiscal de una venta (/ventas) o de una orden
 * (/ventas/ordenes): el badge de estado (con Realtime, `FiscalDocumentBadge`),
 * "Factura C 0003-00000501" y, SÓLO si está autorizado, el CAE completo
 * copiable, su vencimiento y "Verificar en ARCA" (constatación pública).
 *
 * Un pendiente, anulado, rechazado o congelado no muestra CAE ni enlace: no es
 * una factura. En móvil el bloque se parte en renglones (`flex-wrap`) y el CAE
 * usa `tabular-nums` + `break-all` para no desbordar a 360 px.
 */

import { useState } from "react"
import { Check, Copy, ExternalLink } from "lucide-react"
import { toast } from "sonner"

import { Button } from "@/components/ui/button"
import { FiscalDocumentBadge } from "@/components/fiscal/FiscalDocumentBadge"
import {
  ARCA_CONSTATACION_URL,
  hasPrintableInvoice,
  invoiceDisplayName,
} from "@/lib/fiscal-comprobante"
import { formatDate } from "@/lib/format"
import type { FiscalDocumentStatus, SaleFiscalState } from "@/lib/types"

interface FiscalInvoiceSummaryProps {
  fiscal: SaleFiscalState
  /** Cuando Realtime trae un estado nuevo (p. ej. se autorizó): el contenedor refresca. */
  onStatusChange?: (status: FiscalDocumentStatus) => void
}

export function FiscalInvoiceSummary({ fiscal, onStatusChange }: FiscalInvoiceSummaryProps) {
  const [copied, setCopied] = useState(false)
  const name = invoiceDisplayName(fiscal)
  const cae = hasPrintableInvoice(fiscal) ? fiscal.cae ?? null : null

  async function copyCae() {
    if (!cae) return
    try {
      await navigator.clipboard.writeText(cae)
      setCopied(true)
      toast.success("CAE copiado")
      setTimeout(() => setCopied(false), 2000)
    } catch {
      toast.error("No se pudo copiar el CAE")
    }
  }

  return (
    <span className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1">
      <FiscalDocumentBadge
        documentId={fiscal.documentId}
        initialStatus={fiscal.status}
        initialFrozen={fiscal.frozen}
        verbose
        onStatusChange={onStatusChange}
      />
      {name && <span className="text-xs text-muted-foreground tabular-nums">{name}</span>}
      {cae && (
        <span className="flex min-w-0 flex-wrap items-center gap-x-1.5 gap-y-0.5 text-xs text-muted-foreground">
          <span className="inline-flex min-w-0 items-center gap-1">
            CAE
            <span className="break-all font-medium text-foreground tabular-nums">{cae}</span>
            <Button
              type="button"
              variant="ghost"
              size="icon"
              className="h-6 w-6 shrink-0 text-muted-foreground hover:text-foreground"
              aria-label={`Copiar CAE ${cae}`}
              onClick={copyCae}
            >
              {copied ? <Check className="h-3.5 w-3.5 text-success" /> : <Copy className="h-3.5 w-3.5" />}
            </Button>
          </span>
          {fiscal.caeDueDate && <span>· vence {formatDate(fiscal.caeDueDate)}</span>}
          <a
            href={ARCA_CONSTATACION_URL}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1 rounded-sm font-medium text-primary underline-offset-2 hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
          >
            Verificar en ARCA
            <ExternalLink className="h-3 w-3" aria-hidden="true" />
          </a>
        </span>
      )}
    </span>
  )
}
