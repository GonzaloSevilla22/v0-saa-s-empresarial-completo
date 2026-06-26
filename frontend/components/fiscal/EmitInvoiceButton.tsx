"use client"

/**
 * facturar-venta-afip — EmitInvoiceButton.
 *
 * Botón "Facturar" para emitir un comprobante AFIP sobre una SalesOrder confirmada
 * que aún no tiene comprobante (fiscal_document_id IS NULL).
 *
 * Comportamiento:
 *   - Visible solo si status='confirmed' y fiscal_document_id es null.
 *   - Deshabilitado mientras la mutación está in-flight.
 *   - Bloqueado con mensaje si el emisor no es monotributista (OQ-1).
 *   - Al éxito: muestra el FiscalDocumentBadge con status 'pending_cae'.
 *
 * Design ref: D1 (endpoint dedicado), OQ-1 (bloquear RI), OQ-3 (200 + pending_cae).
 *
 * Usage:
 *   <EmitInvoiceButton
 *     salesOrderId="uuid"
 *     fiscalDocumentId={null}       // null = puede facturar
 *     status="confirmed"
 *     ivaConditionEmisor="monotributista"
 *     pointOfSaleId={selectedPvId} // opcional
 *   />
 */

import { useState } from "react"
import { Receipt, AlertCircle, Loader2 } from "lucide-react"
import { toast } from "sonner"

import { Button } from "@/components/ui/button"
import { FiscalDocumentBadge, type FiscalDocumentStatus } from "@/components/fiscal/FiscalDocumentBadge"
import { useEmitInvoice } from "@/hooks/data/use-sales-orders"
import type { IvaCondition } from "@/hooks/data/use-fiscal-profile"

// ── Types ─────────────────────────────────────────────────────────────────────

interface EmitInvoiceButtonProps {
  salesOrderId:      string
  salesOrderStatus:  string
  fiscalDocumentId:  string | null
  /** Condición IVA del emisor (del fiscal_profile activo). */
  ivaConditionEmisor: IvaCondition | null | undefined
  /** Punto de venta a usar. Opcional: si hay solo uno el backend lo selecciona. */
  pointOfSaleId?: string | null
  /** Clase CSS extra para el contenedor. */
  className?: string
}

// ── Component ─────────────────────────────────────────────────────────────────

export function EmitInvoiceButton({
  salesOrderId,
  salesOrderStatus,
  fiscalDocumentId: initialFiscalDocumentId,
  ivaConditionEmisor,
  pointOfSaleId,
  className,
}: EmitInvoiceButtonProps) {
  // Estado local del documento fiscal (se actualiza al emitir)
  const [fiscalDocumentId, setFiscalDocumentId] = useState<string | null>(
    initialFiscalDocumentId
  )
  const [fiscalStatus, setFiscalStatus] = useState<FiscalDocumentStatus | null>(
    initialFiscalDocumentId ? "pending_cae" : null
  )

  const emitInvoice = useEmitInvoice(salesOrderId)

  // ── Guards ────────────────────────────────────────────────────────────────

  // Solo mostrar el botón si la orden está confirmada
  if (salesOrderStatus !== "confirmed") return null

  // Si ya hay comprobante, mostrar solo el badge
  if (fiscalDocumentId && fiscalStatus) {
    return (
      <FiscalDocumentBadge
        documentId={fiscalDocumentId}
        initialStatus={fiscalStatus}
        verbose
      />
    )
  }

  // OQ-1: bloquear con mensaje si el emisor no es monotributista
  if (ivaConditionEmisor === "responsable_inscripto") {
    return (
      <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <AlertCircle className="h-3.5 w-3.5 shrink-0 text-amber-500" />
        <span>Facturación A/B no disponible aún</span>
      </div>
    )
  }

  // Si no hay perfil fiscal configurado, mostrar aviso
  if (ivaConditionEmisor === null || ivaConditionEmisor === undefined) {
    return (
      <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <AlertCircle className="h-3.5 w-3.5 shrink-0" />
        <span>Sin perfil fiscal</span>
      </div>
    )
  }

  // ── Handler ───────────────────────────────────────────────────────────────

  async function handleEmit() {
    try {
      const result = await emitInvoice.mutateAsync({
        point_of_sale_id: pointOfSaleId ?? null,
      })
      setFiscalDocumentId(result.fiscal_document_id)
      setFiscalStatus("pending_cae")
      toast.success("Comprobante enviado a ARCA — en trámite")
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error al emitir el comprobante"
      toast.error(msg)
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className={className}>
      <Button
        size="sm"
        variant="outline"
        onClick={handleEmit}
        disabled={emitInvoice.isPending}
        className="gap-1.5 text-xs h-8"
        aria-label="Emitir comprobante AFIP para esta venta"
      >
        {emitInvoice.isPending ? (
          <>
            <Loader2 className="h-3.5 w-3.5 animate-spin" />
            Emitiendo…
          </>
        ) : (
          <>
            <Receipt className="h-3.5 w-3.5" />
            Facturar
          </>
        )}
      </Button>
    </div>
  )
}
