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
 * punto-venta-seleccion (D4, 2026-09-26): el botón resuelve el punto de venta
 * POR SÍ MISMO — las pantallas ya no calculan uno (eso producía los dos bugs:
 * /ventas mandaba `pointsOfSale[0]`, que podía ser inactivo, y /ventas/ordenes
 * mandaba `null` con dos o más activos → P0422 en el 100% de las cuentas que
 * facturan):
 *   - 0 PV activos → aviso "Sin punto de venta" con enlace a la configuración.
 *   - 1 PV activo  → emite al primer clic con ese PV explícito (sin pasos nuevos).
 *   - ≥ 2 activos  → abre `EmitirComprobanteDialog` con la preselección de
 *                    `resolvePreselectedPointOfSale` (última elección de la
 *                    sesión > predeterminado). Lo que el usuario ve marcado es
 *                    lo que se manda: el PV va SIEMPRE explícito, nunca `null`.
 *   - Tras un OK se recuerda la elección en sessionStorage por cuenta (D8). Se
 *     lee en el momento de abrir, no al montar: en /ventas/ordenes hay un botón
 *     por fila montados a la vez, y lo que eligió una fila tiene que verlo la
 *     siguiente.
 *
 * Design ref: D1 (endpoint dedicado), OQ-1 (bloquear RI), OQ-3 (200 + pending_cae).
 *
 * Usage:
 *   <EmitInvoiceButton
 *     salesOrderId="uuid"
 *     fiscalDocumentId={null}       // null = puede facturar
 *     salesOrderStatus="confirmed"
 *     ivaConditionEmisor="monotributista"
 *   />
 */

import { useState } from "react"
import Link from "next/link"
import { Receipt, AlertCircle, Loader2, ExternalLink } from "lucide-react"
import { toast } from "sonner"

import { Button } from "@/components/ui/button"
import { FiscalDocumentBadge, type FiscalDocumentStatus } from "@/components/fiscal/FiscalDocumentBadge"
import { EmitirComprobanteDialog } from "@/components/fiscal/EmitirComprobanteDialog"
import { useEmitInvoice } from "@/hooks/data/use-sales-orders"
import { useFiscalProfile, type IvaCondition } from "@/hooks/data/use-fiscal-profile"
import { usePointsOfSale } from "@/hooks/data/use-points-of-sale"
import { readSessionValue, writeSessionValue } from "@/hooks/persistence/use-session-storage"
import {
  activePointsOfSale,
  lastPointOfSaleStorageKey,
  resolvePreselectedPointOfSale,
} from "@/lib/fiscal-point-of-sale"

// ── Types ─────────────────────────────────────────────────────────────────────

interface EmitInvoiceButtonProps {
  salesOrderId:      string
  salesOrderStatus:  string
  fiscalDocumentId:  string | null
  /** Condición IVA del emisor (del fiscal_profile activo). */
  ivaConditionEmisor: IvaCondition | null | undefined
  /** Clase CSS extra para el contenedor. */
  className?: string
  /**
   * venta-editable-vs-promocion-legacy: texto del botón. Default "Facturar"
   * (/ventas/ordenes). En /ventas es el SEGUNDO paso — el primero ya se llamó
   * "Facturar" — así que el listado pasa "Emitir comprobante".
   */
  label?: string
  /**
   * Se llama cuando la emisión falla (después del toast), para que el
   * contenedor vuelva la fila a su estado inicial: en /ventas el próximo
   * "Facturar" re-prepara la venta (re-sincroniza una orden desactualizada).
   */
  onEmitFailed?: () => void
}

// ── Component ─────────────────────────────────────────────────────────────────

export function EmitInvoiceButton({
  salesOrderId,
  salesOrderStatus,
  fiscalDocumentId: initialFiscalDocumentId,
  ivaConditionEmisor,
  className,
  label = "Facturar",
  onEmitFailed,
}: EmitInvoiceButtonProps) {
  // Estado local del documento fiscal (se actualiza al emitir)
  const [fiscalDocumentId, setFiscalDocumentId] = useState<string | null>(
    initialFiscalDocumentId
  )
  const [fiscalStatus, setFiscalStatus] = useState<FiscalDocumentStatus | null>(
    initialFiscalDocumentId ? "pending_cae" : null
  )
  const [dialogOpen, setDialogOpen] = useState(false)
  const [preselectedPvId, setPreselectedPvId] = useState<string | null>(null)

  const emitInvoice = useEmitInvoice(salesOrderId)
  // TanStack Query cachea las dos listas (5 min) y las dos pantallas ya las
  // consultan: no agrega requests.
  const { pointsOfSale, isLoading: pvLoading, isError: pvError } = usePointsOfSale()
  const { profile: fiscalProfile } = useFiscalProfile()

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
        <AlertCircle className="h-3.5 w-3.5 shrink-0 text-warning" />
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

  if (pvError) {
    return (
      <div className="flex items-center gap-1.5 text-xs text-muted-foreground">
        <AlertCircle className="h-3.5 w-3.5 shrink-0 text-warning" />
        <span>No se pudieron cargar los puntos de venta</span>
      </div>
    )
  }

  const activePVs = activePointsOfSale(pointsOfSale)

  if (!pvLoading && activePVs.length === 0) {
    return (
      <div className="flex flex-wrap items-center gap-1.5 text-xs text-muted-foreground">
        <AlertCircle className="h-3.5 w-3.5 shrink-0 text-warning" />
        <span>Sin punto de venta</span>
        <Link
          href="/configuracion/fiscal"
          className="inline-flex items-center gap-1 underline underline-offset-2 hover:text-foreground"
        >
          Configurar <ExternalLink className="h-3 w-3" />
        </Link>
      </div>
    )
  }

  // La memoria de la sesión es por cuenta; el accountId viaja en la fila del PV.
  const storageKey = activePVs[0] ? lastPointOfSaleStorageKey(activePVs[0].accountId) : null

  // ── Handlers ──────────────────────────────────────────────────────────────

  async function emitWith(pointOfSaleId: string) {
    try {
      const result = await emitInvoice.mutateAsync({ point_of_sale_id: pointOfSaleId })
      if (storageKey) writeSessionValue(storageKey, pointOfSaleId)
      setDialogOpen(false)
      setFiscalDocumentId(result.fiscal_document_id)
      setFiscalStatus("pending_cae")
      toast.success("Comprobante enviado a ARCA — en trámite")
    } catch (err: unknown) {
      setDialogOpen(false)
      const msg = err instanceof Error ? err.message : "Error al emitir el comprobante"
      toast.error(msg)
      onEmitFailed?.()
    }
  }

  function handleClick() {
    if (activePVs.length === 1) {
      void emitWith(activePVs[0].id)
      return
    }
    const lastUsedId = storageKey ? readSessionValue<string>(storageKey) : null
    setPreselectedPvId(resolvePreselectedPointOfSale(pointsOfSale, { lastUsedId }))
    setDialogOpen(true)
  }

  // ── Render ────────────────────────────────────────────────────────────────

  return (
    <div className={className}>
      <Button
        size="sm"
        variant="outline"
        onClick={handleClick}
        disabled={emitInvoice.isPending || pvLoading}
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
            {label}
          </>
        )}
      </Button>

      {activePVs.length > 1 && (
        <EmitirComprobanteDialog
          open={dialogOpen}
          onOpenChange={(next) => {
            if (!emitInvoice.isPending) setDialogOpen(next)
          }}
          pointsOfSale={pointsOfSale}
          fiscalProfile={fiscalProfile}
          preselectedPointOfSaleId={preselectedPvId}
          onConfirm={(pvId) => void emitWith(pvId)}
          isSubmitting={emitInvoice.isPending}
        />
      )}
    </div>
  )
}
