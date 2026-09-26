"use client"

/**
 * v22-afip-delegation-billing — EmitirComprobanteDialog
 * punto-venta-seleccion (D10, 2026-09-26) — revivido: era código muerto desde
 * v22 (ningún consumidor). Lo abre `EmitInvoiceButton` cuando la cuenta tiene
 * DOS o más puntos de venta activos, en los dos caminos de facturación de
 * ventas (/ventas y /ventas/ordenes).
 *
 * Diálogo de confirmación para emitir un comprobante electrónico (CAE ARCA).
 * La emisión es SIEMPRE deliberada: el usuario confirma explícitamente, y el
 * PV que ve marcado es el que se manda — explícito, nunca `null` (D4).
 *
 * Qué cambió al revivirlo:
 *   - el selector es `PointOfSaleSelect` (el único de la app, D7), con el
 *     badge "Predeterminado";
 *   - abre con la preselección que resuelve el caller
 *     (`resolvePreselectedPointOfSale`: última elección de la sesión >
 *     predeterminado); sin preselección, confirmar queda deshabilitado hasta
 *     elegir;
 *   - la delegación ARCA no autorizada pasa de BLOQUEO a AVISO (OQ-4): el
 *     camino de un solo PV nunca lo tuvo, la RPC no lo verifica, y con el
 *     bloqueo una cuenta de varios PV quedaba más restringida que una de uno;
 *   - tokens semánticos de advertencia (antes `amber-*` literales).
 *
 * No realiza mutaciones — delega al caller (`onConfirm`).
 */

import { useEffect, useState } from "react"
import Link from "next/link"
import { AlertCircle, FileText, ExternalLink } from "lucide-react"
import { Button } from "@/components/ui/button"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog"
import { PointOfSaleSelect } from "@/components/fiscal/PointOfSaleSelect"
import { activePointsOfSale } from "@/lib/fiscal-point-of-sale"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"
import type { FiscalProfile } from "@/hooks/data/use-fiscal-profile"

// ── Types ─────────────────────────────────────────────────────────────────────

interface EmitirComprobanteDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Texto que identifica la operación (ej. "Venta del 24/06"). Opcional. */
  operationLabel?: string
  pointsOfSale: PointOfSale[]
  fiscalProfile: FiscalProfile | null
  /** PV a marcar al abrir (o `null`: el usuario elige). */
  preselectedPointOfSaleId: string | null
  /** Called when the user confirms — receives the selected point_of_sale_id */
  onConfirm: (pointOfSaleId: string) => void
  isSubmitting: boolean
}

// ── IVA condition → comprobante type display ──────────────────────────────────

function comprobanteLabel(ivaCondition: FiscalProfile["ivaCondition"] | undefined): string {
  switch (ivaCondition) {
    case "monotributista":       return "Factura C"
    case "responsable_inscripto": return "Factura A / B"
    case "exento":               return "Factura C"
    default:                     return "Comprobante electrónico"
  }
}

/** Superficie de advertencia (patrón superficie/texto de tokens-contraste-aa). */
const WARNING_SURFACE = "flex items-start gap-2 rounded-md border border-warning/25 bg-warning/10 p-3 text-sm text-foreground"

// ── Component ─────────────────────────────────────────────────────────────────

export function EmitirComprobanteDialog({
  open,
  onOpenChange,
  operationLabel,
  pointsOfSale,
  fiscalProfile,
  preselectedPointOfSaleId,
  onConfirm,
  isSubmitting,
}: EmitirComprobanteDialogProps) {
  const activePVs = activePointsOfSale(pointsOfSale)
  const [selectedPvId, setSelectedPvId] = useState<string>(preselectedPointOfSaleId ?? "")

  // Cada apertura arranca de la preselección vigente (no de la elección de una
  // apertura anterior que se canceló).
  useEffect(() => {
    if (open) setSelectedPvId(preselectedPointOfSaleId ?? "")
  }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  const noProfile    = fiscalProfile === null
  const noPVs        = activePVs.length === 0
  const delegationOk = fiscalProfile?.delegacionAutorizada ?? false
  const selectionIsActive = activePVs.some((pv) => pv.id === selectedPvId)

  const canConfirm = !isSubmitting && !noProfile && !noPVs && selectionIsActive

  const comprobanteType = comprobanteLabel(fiscalProfile?.ivaCondition)

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-card-foreground">
            <FileText className="h-5 w-5 text-primary" />
            Enviar al ARCA — Obtener CAE
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Vas a emitir un comprobante electrónico para{" "}
            {operationLabel ? <strong className="text-foreground">{operationLabel}</strong> : "esta venta"}.
            Esta acción genera un documento fiscal real ante AFIP/ARCA.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4 py-2">
          {/* No fiscal profile */}
          {noProfile && (
            <div className="flex items-start gap-2 rounded-md border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
              <div className="flex flex-col gap-1">
                <span className="font-medium">Perfil fiscal no configurado</span>
                <span className="text-xs">Configurá tu CUIT y condición IVA antes de emitir.</span>
                <Link
                  href="/configuracion/fiscal"
                  className="text-xs underline underline-offset-2 hover:opacity-80 flex items-center gap-1"
                  onClick={() => onOpenChange(false)}
                >
                  Ir a Datos fiscales <ExternalLink className="h-3 w-3" />
                </Link>
              </div>
            </div>
          )}

          {/* No active PVs */}
          {!noProfile && noPVs && (
            <div className={WARNING_SURFACE}>
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0 text-warning" />
              <div className="flex flex-col gap-1">
                <span className="font-medium">Sin puntos de venta activos</span>
                <span className="text-xs text-muted-foreground">Creá al menos un punto de venta para poder emitir.</span>
                <Link
                  href="/configuracion/fiscal"
                  className="text-xs underline underline-offset-2 hover:opacity-80 flex items-center gap-1"
                  onClick={() => onOpenChange(false)}
                >
                  Configurar puntos de venta <ExternalLink className="h-3 w-3" />
                </Link>
              </div>
            </div>
          )}

          {!noProfile && !noPVs && (
            <>
              {/* Delegation not authorized — aviso, NO bloqueo (OQ-4) */}
              {!delegationOk && (
                <div className={WARNING_SURFACE} role="status">
                  <AlertCircle className="h-4 w-4 mt-0.5 shrink-0 text-warning" />
                  <div className="flex flex-col gap-1">
                    <span className="font-medium">Delegación en ARCA no autorizada</span>
                    <span className="text-xs text-muted-foreground">
                      Si todavía no autorizaste a Aliadata a facturar en tu nombre, ARCA va a
                      rechazar el comprobante. Autorizá la delegación y confirmalo en Datos fiscales.
                    </span>
                    <Link
                      href="/configuracion/fiscal"
                      className="text-xs underline underline-offset-2 hover:opacity-80 flex items-center gap-1"
                      onClick={() => onOpenChange(false)}
                    >
                      Configurar autorización <ExternalLink className="h-3 w-3" />
                    </Link>
                  </div>
                </div>
              )}

              <div className="rounded-md border border-border bg-muted/30 p-3 text-sm">
                <div className="flex items-center justify-between gap-2">
                  <span className="text-muted-foreground">Tipo de comprobante</span>
                  <span className="font-semibold text-foreground">{comprobanteType}</span>
                </div>
                <p className="text-xs text-muted-foreground mt-1">
                  Resuelto por el backend según tu condición IVA — no editable aquí.
                </p>
              </div>

              <PointOfSaleSelect
                pointsOfSale={pointsOfSale}
                value={selectedPvId}
                onValueChange={setSelectedPvId}
                disabled={isSubmitting}
              />

              <div className="rounded-md border border-primary/20 bg-primary/5 p-3 text-xs text-muted-foreground">
                <strong className="text-foreground">Atención:</strong> esta acción genera un comprobante fiscal
                real ante AFIP. Solo confirmá si la operación es real y querés emitir factura electrónica.
              </div>
            </>
          )}
        </div>

        <DialogFooter className="gap-2 sm:gap-0">
          <Button
            variant="outline"
            onClick={() => onOpenChange(false)}
            disabled={isSubmitting}
            className="border-border text-foreground"
          >
            Cancelar
          </Button>
          <Button
            onClick={() => onConfirm(selectedPvId)}
            disabled={!canConfirm}
            className="gap-2"
          >
            {isSubmitting ? "Enviando a ARCA…" : "Confirmar y enviar al ARCA"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
