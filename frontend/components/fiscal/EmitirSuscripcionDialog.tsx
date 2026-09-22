"use client"

/**
 * v22-afip-delegation-billing — EmitirSuscripcionDialog
 *
 * Dialog para emitir Factura C por un pago de suscripción SaaS.
 * Solo para el admin de plataforma (Aliadata, monotributista).
 *
 * Flujo:
 *   1. El admin hace clic en "Enviar al ARCA" en admin/pagos.
 *   2. Se muestra este dialog con datos del recibo (cliente, monto, plan).
 *   3. El admin ingresa el CUIT o DNI del receptor y confirma.
 *   4. El caller (admin/pagos/page.tsx) llama a useEmitSubscriptionPayment.
 *
 * Validación CUIT/DNI:
 *   - CUIT: módulo-11 vía isValidCuit (lib/cuit-utils.ts)
 *   - DNI: 7-8 dígitos vía isValidTaxId
 *   - Si empieza con dígitos del tipo CUIT (NN-), requiere CUIT válido.
 *   - Si tiene 7-8 dígitos numéricos, es DNI (DocTipo=96).
 *
 * fiscal-emision-segura (G5/H3, 2026-09-22): el receptor pasa a ser OPCIONAL.
 * Un selector de modo permite emitir a "Consumidor final (sin identificar)",
 * que ante ARCA es DocTipo=99 / DocNro=0 — el mismo caso de una factura de
 * mostrador. El bloqueo era sólo de esta pantalla y del schema Pydantic: la RPC
 * y el adapter ya lo soportaban. Es excluyente, así que va con RadioGroup y no
 * con un Checkbox.
 *
 * Props:
 *   open / onOpenChange      — control del dialog
 *   receipt                  — datos del recibo (customer, amount, plan)
 *   pointsOfSale             — PVs del admin (para selector multi-PV)
 *   onConfirm(payload)       — callback con los datos de emisión
 *   isSubmitting             — bloquea mientras el caller procesa
 *
 * Reglas duras:
 *   - NUNCA usar `any`
 *   - NUNCA emitir automáticamente — el admin debe confirmar explícitamente
 *   - PascalCase para el componente y el archivo
 */

import { useState, useEffect, useId } from "react"
import Link from "next/link"
import { AlertCircle, FileText, ExternalLink } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
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
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group"
import { isValidCuit, isValidTaxId, isCuitFormat } from "@/lib/cuit-utils"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"
import type { EmitSubscriptionPaymentInput, ReceptorDocTipo } from "@/hooks/data/use-emit-subscription-payment"

// ── Types ─────────────────────────────────────────────────────────────────────

export interface SubscriptionReceipt {
  id: string
  receipt_number: string | null
  payment_id: string | null
  plan: string | null
  amount: number | null
  customer_email: string
  customer_name: string | null
}

interface EmitirSuscripcionDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  receipt: SubscriptionReceipt | null
  pointsOfSale: PointOfSale[]
  onConfirm: (payload: EmitSubscriptionPaymentInput) => void
  isSubmitting: boolean
}

// ── Helpers ───────────────────────────────────────────────────────────────────

const PLAN_LABELS: Record<string, string> = {
  gratis: "Gratis", inicial: "Inicial", avanzado: "Avanzado", pro: "Pro",
}

function formatAmount(amount: number | null): string {
  if (amount == null) return "—"
  return new Intl.NumberFormat("es-AR", {
    style: "currency", currency: "ARS", minimumFractionDigits: 2,
  }).format(amount)
}

/**
 * Infiere el DocTipo AFIP desde el valor ingresado:
 *   - CUIT formato NN-NNNNNNNN-N → 80
 *   - 7-8 dígitos numéricos → 96 (DNI)
 *   - Otherwise → null (no se puede determinar aún)
 */
function inferDocTipo(value: string): ReceptorDocTipo | null {
  const trimmed = value.trim()
  if (isCuitFormat(trimmed)) return 80
  if (/^\d{7,8}$/.test(trimmed)) return 96
  return null
}

/** Normaliza el doc_nro: elimina guiones para enviar al backend. */
function normalizeDocNro(value: string, docTipo: ReceptorDocTipo | null): string {
  if (docTipo === 80) return value.trim().replace(/-/g, "")
  return value.trim()
}

/**
 * Modo de identificación del receptor (G5/H3).
 *   "identified"  → CUIT (DocTipo 80) o DNI (DocTipo 96), comportamiento previo.
 *   "final"       → consumidor final sin identificar: DocTipo 99 / DocNro 0.
 */
type ReceptorMode = "identified" | "final"

/** Umbral de identificación obligatoria del receptor — RG 5824/2026.
 *  Espejo de `afip_consumidor_final_threshold` (backend/core/config.py); el
 *  adapter es el que lo verifica de verdad antes de pedir el CAE. */
const RECEPTOR_REQUIRED_THRESHOLD_LABEL = "$10.000.000"

// ── Component ─────────────────────────────────────────────────────────────────

export function EmitirSuscripcionDialog({
  open,
  onOpenChange,
  receipt,
  pointsOfSale,
  onConfirm,
  isSubmitting,
}: EmitirSuscripcionDialogProps) {
  const docInputId = useId()
  const pvSelectId = useId()

  const receptorModeId = useId()

  const activePVs = pointsOfSale.filter((pv) => pv.isActive)
  const [docValue, setDocValue] = useState("")
  const [docError, setDocError] = useState<string | null>(null)
  const [selectedPvId, setSelectedPvId] = useState<string>("")
  // Default "identified": preserva exactamente el comportamiento previo.
  const [receptorMode, setReceptorMode] = useState<ReceptorMode>("identified")

  // Auto-select single active PV
  useEffect(() => {
    if (activePVs.length === 1 && !selectedPvId) {
      setSelectedPvId(activePVs[0].id)
    }
  }, [activePVs, selectedPvId])

  // Reset state on dialog open/close
  useEffect(() => {
    if (!open) {
      setDocValue("")
      setDocError(null)
      setSelectedPvId(activePVs.length === 1 ? (activePVs[0]?.id ?? "") : "")
      setReceptorMode("identified")
    }
  }, [open]) // eslint-disable-line react-hooks/exhaustive-deps

  const docTipo = inferDocTipo(docValue)

  // Live validation feedback
  function validateDoc(value: string): string | null {
    const trimmed = value.trim()
    if (!trimmed) return null
    if (isCuitFormat(trimmed)) {
      return isValidCuit(trimmed) ? null : "CUIT inválido: verificá el dígito verificador (módulo 11)."
    }
    if (/^\d+$/.test(trimmed)) {
      if (trimmed.length < 7) return "DNI muy corto (mínimo 7 dígitos)."
      if (trimmed.length > 8) return "El número tiene más de 8 dígitos. ¿Es un CUIT? Formato: NN-NNNNNNNN-N."
      return null // valid DNI
    }
    if (trimmed.length > 0 && !/^\d[\d-]*$/.test(trimmed)) {
      return "Solo dígitos y guiones son válidos."
    }
    return null
  }

  function handleDocChange(value: string) {
    setDocValue(value)
    setDocError(validateDoc(value))
  }

  /** Al cambiar de modo se limpia lo tipeado: sin esto, un CUIT inválido escrito
   *  antes podía volver al confirmar si el usuario iba y venía entre modos. */
  function handleReceptorModeChange(value: string) {
    setReceptorMode(value === "final" ? "final" : "identified")
    setDocValue("")
    setDocError(null)
  }

  const isConsumidorFinal = receptorMode === "final"

  const isDocValid = docValue.trim().length > 0 &&
    docError === null &&
    isValidTaxId(docValue.trim())

  const isPvSelected = activePVs.length === 0 || selectedPvId !== ""

  const canConfirm =
    !isSubmitting &&
    receipt !== null &&
    isPvSelected &&
    (isConsumidorFinal || (isDocValid && docTipo !== null))

  function handleConfirm() {
    if (!receipt) return
    if (isConsumidorFinal) {
      // DocTipo 99 / DocNro 0 los resuelve el adapter a partir de los nulls.
      onConfirm({
        receipt_id:        receipt.id,
        receptor_doc_tipo: null,
        receptor_doc_nro:  null,
        point_of_sale_id:  selectedPvId || null,
      })
      return
    }
    if (docTipo === null) return
    const normalizedNro = normalizeDocNro(docValue, docTipo)
    onConfirm({
      receipt_id:        receipt.id,
      receptor_doc_tipo: docTipo,
      receptor_doc_nro:  normalizedNro,
      point_of_sale_id:  selectedPvId || null,
    })
  }

  const docTypeLabel = docTipo === 80 ? "CUIT" : docTipo === 96 ? "DNI" : null

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border sm:max-w-md">
        <DialogHeader>
          <DialogTitle className="flex items-center gap-2 text-card-foreground">
            <FileText className="h-5 w-5 text-primary" />
            Enviar al ARCA — Factura C de suscripción
          </DialogTitle>
          <DialogDescription className="text-muted-foreground">
            Emitir Factura C a nombre de Aliadata (monotributista) por el pago de suscripción.
            Esta acción genera un documento fiscal real ante AFIP/ARCA.
          </DialogDescription>
        </DialogHeader>

        {/* fiscal-emision-segura (G5, pasada visual de 375 px): el selector de
            receptor sumó ~130 px de alto y el CTA primario se iba abajo del
            viewport en un teléfono (medido: 883,6 px de fondo contra 812 de
            alto). El cuerpo scrollea SOLO en pantallas chicas y el footer queda
            fijo, así que "Confirmar y enviar al ARCA" sigue siempre a la vista;
            en desktop (sm+) no cambia nada — ahí el diálogo entra completo. */}
        <div className="flex max-h-[58dvh] flex-col gap-4 overflow-y-auto py-2 sm:max-h-none sm:overflow-visible">
          {/* Receipt summary */}
          {receipt && (
            <div className="rounded-md border border-border bg-muted/30 p-3 text-sm space-y-1.5">
              <div className="flex items-center justify-between gap-2">
                <span className="text-muted-foreground">Cliente</span>
                <span className="font-medium text-foreground text-right">
                  {receipt.customer_name ?? receipt.customer_email}
                </span>
              </div>
              <div className="flex items-center justify-between gap-2">
                <span className="text-muted-foreground">Email</span>
                <span className="text-xs text-foreground">{receipt.customer_email}</span>
              </div>
              <div className="flex items-center justify-between gap-2">
                <span className="text-muted-foreground">Plan</span>
                <span className="text-foreground">
                  {PLAN_LABELS[receipt.plan ?? ""] ?? receipt.plan ?? "—"}
                </span>
              </div>
              <div className="flex items-center justify-between gap-2">
                <span className="text-muted-foreground">Monto</span>
                <span className="font-semibold text-foreground">{formatAmount(receipt.amount)}</span>
              </div>
              <div className="flex items-center justify-between gap-2">
                <span className="text-muted-foreground">Recibo</span>
                <span className="font-mono text-xs text-foreground">{receipt.receipt_number ?? receipt.id}</span>
              </div>
            </div>
          )}

          {/* Comprobante type (fixed) */}
          <div className="rounded-md border border-border bg-muted/30 p-3 text-sm">
            <div className="flex items-center justify-between gap-2">
              <span className="text-muted-foreground">Tipo de comprobante</span>
              <span className="font-semibold text-foreground">Factura C</span>
            </div>
            <p className="text-xs text-muted-foreground/70 mt-1">
              Aliadata es monotributista — siempre emite Factura C.
            </p>
          </div>

          {/* No active PVs */}
          {activePVs.length === 0 && (
            <div className="flex items-start gap-2 rounded-md border border-amber-500/30 bg-amber-500/10 p-3 text-sm text-amber-700 dark:text-amber-400">
              <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
              <div className="flex flex-col gap-1">
                <span className="font-medium">Sin puntos de venta activos</span>
                <span className="text-xs">Configurá el perfil fiscal de Aliadata.</span>
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

          {/* PV selector */}
          {activePVs.length > 1 && (
            <div className="flex flex-col gap-1.5">
              <Label htmlFor={pvSelectId}>Punto de venta</Label>
              <Select value={selectedPvId} onValueChange={setSelectedPvId}>
                <SelectTrigger id={pvSelectId} className="bg-background border-border text-foreground">
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
          )}

          {activePVs.length === 1 && (
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

          {/* Receptor: identificado o consumidor final (G5/H3) */}
          <div className="flex flex-col gap-2">
            <Label id={receptorModeId}>Receptor</Label>
            <RadioGroup
              aria-labelledby={receptorModeId}
              value={receptorMode}
              onValueChange={handleReceptorModeChange}
              className="gap-2"
            >
              <label className="flex items-start gap-2 text-sm text-foreground">
                <RadioGroupItem
                  value="identified"
                  id="receptor-identified"
                  disabled={isSubmitting}
                  className="mt-0.5"
                />
                <span>Identificado con CUIT o DNI</span>
              </label>
              <label className="flex items-start gap-2 text-sm text-foreground">
                <RadioGroupItem
                  value="final"
                  id="receptor-final"
                  disabled={isSubmitting}
                  className="mt-0.5"
                />
                <span className="flex flex-col gap-0.5">
                  <span>Consumidor final (sin identificar)</span>
                  <span className="text-xs text-muted-foreground">
                    Se emite con DocTipo 99 / DocNro 0, como una factura de mostrador.
                    ARCA exige identificar al receptor a partir de{" "}
                    {RECEPTOR_REQUIRED_THRESHOLD_LABEL} (RG 5824/2026); un pago de
                    suscripción está muy por debajo.
                  </span>
                </span>
              </label>
            </RadioGroup>
          </div>

          {/* CUIT / DNI input */}
          {!isConsumidorFinal && (
          <div className="flex flex-col gap-1.5">
            <Label htmlFor={docInputId}>
              CUIT o DNI del receptor
              {docTypeLabel && (
                <span className="ml-2 text-xs font-normal text-muted-foreground">
                  (detectado: {docTypeLabel})
                </span>
              )}
            </Label>
            <Input
              id={docInputId}
              type="text"
              inputMode="numeric"
              value={docValue}
              onChange={(e) => handleDocChange(e.target.value)}
              placeholder="20-12345678-6 o 12345678"
              className="bg-background border-border text-foreground font-mono"
              disabled={isSubmitting}
            />
            {docError && (
              <p className="text-xs text-destructive">{docError}</p>
            )}
            {!docError && !docValue && (
              <p className="text-xs text-muted-foreground">
                CUIT: formato NN-NNNNNNNN-N con dígito verificador. DNI: 7 u 8 dígitos.
              </p>
            )}
            {!docError && docValue && isDocValid && (
              <p className="text-xs text-green-600 dark:text-green-400">
                {docTipo === 80 ? "CUIT válido (módulo 11 ok)" : "DNI válido"}
              </p>
            )}
          </div>
          )}

          {/* Warning */}
          <div className="rounded-md border border-primary/20 bg-primary/5 p-3 text-xs text-muted-foreground">
            <strong className="text-foreground">Atención:</strong> esta acción genera un comprobante
            fiscal real ante AFIP. Solo confirmá si el pago de suscripción es real y querés emitir
            factura electrónica.
          </div>
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
            onClick={handleConfirm}
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
