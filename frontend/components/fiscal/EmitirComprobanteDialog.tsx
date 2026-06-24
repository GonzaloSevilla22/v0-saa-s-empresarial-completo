"use client"

/**
 * v22-afip-delegation-billing — EmitirComprobanteDialog
 *
 * Dialog de confirmación para emitir un comprobante electrónico (CAE ARCA).
 * La emisión es SIEMPRE deliberada: el usuario debe confirmar explícitamente.
 *
 * Props:
 *   open / onOpenChange      — control del dialog
 *   operationLabel           — texto libre para identificar la operación (ej. "Venta $1.200")
 *   pointsOfSale             — lista de PVs activos de la cuenta
 *   fiscalProfile            — perfil fiscal (para mostrar condición IVA y estado delegación)
 *   onConfirm(pvId)          — callback cuando el usuario confirma; recibe el point_of_sale_id elegido
 *   isSubmitting             — bloquea el botón mientras el caller está procesando
 *
 * No realiza mutaciones directamente — delega al caller (ventas/page o pos/page).
 * Eso mantiene la lógica de negocio en el hook de datos.
 */

import { useState, useEffect } from "react"
import Link from "next/link"
import { AlertCircle, FileText, ExternalLink } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogFooter,
} from "@/components/ui/dialog"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"
import type { FiscalProfile } from "@/hooks/data/use-fiscal-profile"

// ── Types ─────────────────────────────────────────────────────────────────────

interface EmitirComprobanteDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Label for the operation being emitted (e.g. "Venta del 24/06") */
  operationLabel: string
  pointsOfSale: PointOfSale[]
  fiscalProfile: FiscalProfile | null
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

// ── Component ─────────────────────────────────────────────────────────────────

export function EmitirComprobanteDialog({
  open,
  onOpenChange,
  operationLabel,
  pointsOfSale,
  fiscalProfile,
  onConfirm,
  isSubmitting,
}: EmitirComprobanteDialogProps) {
  const activePVs = pointsOfSale.filter((pv) => pv.isActive)

  // Auto-select if only one active PV
  const [selectedPvId, setSelectedPvId] = useState<string>("")

  useEffect(() => {
    if (activePVs.length === 1 && !selectedPvId) {
      setSelectedPvId(activePVs[0].id)
    }
  }, [activePVs, selectedPvId])

  // Reset on dialog close
  useEffect(() => {
    if (!open) {
      setSelectedPvId(activePVs.length === 1 ? (activePVs[0]?.id ?? "") : "")
    }
  }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  const delegationOk = fiscalProfile?.delegacionAutorizada ?? false
  const noProfile    = fiscalProfile === null
  const noPVs        = activePVs.length === 0

  const canConfirm =
    !isSubmitting &&
    !noProfile &&
    !noPVs &&
    delegationOk &&
    selectedPvId !== ""

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
            Vas a emitir un comprobante electrónico para <strong className="text-foreground">{operationLabel}</strong>.
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
            <div className="flex items-start gap-2 rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-amber-700 dark:text-amber-400">
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
              <div className="flex flex-col gap-1">
                <span className="font-medium">Sin puntos de venta activos</span>
                <span className="text-xs">Creá al menos un punto de venta para poder emitir.</span>
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

          {/* Delegation not authorized */}
          {!noProfile && !noPVs && !delegationOk && (
            <div className="flex items-start gap-2 rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-amber-700 dark:text-amber-400">
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
              <div className="flex flex-col gap-1">
                <span className="font-medium">Delegación en ARCA no autorizada</span>
                <span className="text-xs">
                  Aliadata aún no tiene autorización para emitir en tu nombre.
                  Autorizá la delegación en ARCA y confirmá en Datos fiscales.
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

          {/* Ready state — show comprobante type + PV selector */}
          {!noProfile && !noPVs && delegationOk && (
            <>
              <div className="rounded-md border border-border bg-muted/30 p-3 text-sm">
                <div className="flex items-center justify-between gap-2">
                  <span className="text-muted-foreground">Tipo de comprobante</span>
                  <span className="font-semibold text-foreground">{comprobanteType}</span>
                </div>
                <p className="text-xs text-muted-foreground/70 mt-1">
                  Resuelto por el backend según tu condición IVA — no editable aquí.
                </p>
              </div>

              {activePVs.length > 1 ? (
                <div className="flex flex-col gap-1.5">
                  <Label>Punto de venta</Label>
                  <Select value={selectedPvId} onValueChange={setSelectedPvId}>
                    <SelectTrigger className="bg-background border-border text-foreground">
                      <SelectValue placeholder="Seleccioná un PV" />
                    </SelectTrigger>
                    <SelectContent className="bg-popover border-border">
                      {activePVs.map((pv) => (
                        <SelectItem key={pv.id} value={pv.id}>
                          PV {String(pv.numero).padStart(5, "0")}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                </div>
              ) : (
                <div className="rounded-md border border-border bg-muted/30 p-3 text-sm">
                  <div className="flex items-center justify-between gap-2">
                    <span className="text-muted-foreground">Punto de venta</span>
                    <span className="font-semibold text-foreground">
                      PV {String(activePVs[0]?.numero ?? 1).padStart(5, "0")}
                    </span>
                  </div>
                  <p className="text-xs text-muted-foreground/70 mt-1">
                    Único PV activo — seleccionado automáticamente.
                  </p>
                </div>
              )}

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
