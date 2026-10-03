"use client"

/**
 * remitos-venta (D11, tarea 5.3) — diálogo de anulación de un remito pendiente.
 *
 * Anular repone en el stock de la sucursal todo lo que el remito retiene y deja
 * el documento `canceled`: es terminal y sólo lo hace admin/owner, así que el
 * diálogo (1) exige un motivo de 3 a 500 caracteres, (2) enumera lo que vuelve
 * ("Vuelven a Sucursal Centro: 3 × Producto A, 0,450 kg de Producto B") y (3)
 * manda la `revision` que se mostró: si otro usuario editó el remito mientras
 * tanto, el servidor responde `delivery_note_changed` y no anula a ciegas.
 *
 * Un error deja el diálogo abierto con el motivo escrito. El foco entra al
 * motivo al abrir; quien lo abrió (`CancelDeliveryNoteDialog` no tiene
 * `Trigger`) lo recupera con `useRestoreFocus` en la página.
 */
import { useEffect, useMemo, useRef, useState } from "react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { useCancelDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useProducts } from "@/hooks/data/use-products"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { describeHeldReturn } from "@/lib/delivery-note-stock"
import type { DeliveryNoteApiRow } from "@/lib/delivery-note-types"
import { humanizeOperationError } from "@/lib/operation-errors"
import { resolveUnit } from "@/lib/unit-utils"

const REASON_MIN = 3
const REASON_MAX = 500

export interface CancelDeliveryNoteDialogProps {
  deliveryNote: DeliveryNoteApiRow
  open: boolean
  onOpenChange: (open: boolean) => void
}

export function CancelDeliveryNoteDialog({ deliveryNote, open, onOpenChange }: CancelDeliveryNoteDialogProps) {
  const cancel = useCancelDeliveryNote()
  const { products } = useProducts()
  const { unitsById } = useUnitsOfMeasure()
  const [reason, setReason] = useState("")
  const [submitting, setSubmitting] = useState(false)
  const submittingRef = useRef(false)
  const reasonRef = useRef<HTMLTextAreaElement>(null)

  // Un motivo viejo no sobrevive a una nueva apertura.
  useEffect(() => {
    if (open) setReason("")
  }, [open])

  // El foco entra al motivo cuando el modal ya está montado (el portal de Radix
  // monta después del primer render).
  useEffect(() => {
    if (!open) return
    const id = window.setTimeout(() => reasonRef.current?.focus(), 0)
    return () => window.clearTimeout(id)
  }, [open])

  const branchName = deliveryNote.branch_name ?? "la sucursal"
  const returnText = useMemo(
    () =>
      describeHeldReturn(deliveryNote.items, branchName, (productId) =>
        resolveUnit(products.find((p) => p.id === productId)?.baseUnitId, unitsById),
      ),
    [deliveryNote.items, branchName, products, unitsById],
  )

  const trimmed = reason.trim()
  const reasonValid = trimmed.length >= REASON_MIN && trimmed.length <= REASON_MAX
  const label = deliveryNote.number_label ?? "el remito"

  async function handleSubmit() {
    if (!reasonValid || submittingRef.current) return
    submittingRef.current = true
    setSubmitting(true)
    try {
      await cancel.mutateAsync({
        deliveryNoteId: deliveryNote.id,
        payload: { reason: trimmed, revision: deliveryNote.revision },
      })
      toast.success(`Remito ${label} anulado: el stock volvió a ${branchName}`)
      onOpenChange(false)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : ""
      toast.error(humanizeOperationError(message, undefined, null, { documentLabel: "remito" }).message)
    } finally {
      submittingRef.current = false
      setSubmitting(false)
    }
  }

  return (
    <ResponsiveModal open={open} onOpenChange={onOpenChange} title={`Anular ${label}`}>
      <form
        className="flex flex-col gap-4 overflow-y-auto"
        noValidate
        onSubmit={(event) => {
          event.preventDefault()
          void handleSubmit()
        }}
      >
        <p className="text-sm text-muted-foreground">
          Anular es definitivo: el remito queda sin efecto y no se puede reabrir. Para corregir un dato, editalo en lugar de
          anularlo.
        </p>
        <p
          role="status"
          aria-label="Stock que vuelve"
          className="rounded-lg border border-border bg-accent/40 px-3 py-2 text-sm text-foreground"
        >
          {returnText}
        </p>
        <div className="flex flex-col gap-2">
          <Label htmlFor="delivery-note-cancel-reason" className="flex items-center justify-between gap-2 text-foreground">
            <span>Motivo de la anulación</span>
            <span className="text-xs font-normal text-muted-foreground tabular-nums">
              {reason.length}/{REASON_MAX}
            </span>
          </Label>
          <Textarea
            id="delivery-note-cancel-reason"
            ref={reasonRef}
            value={reason}
            maxLength={REASON_MAX}
            onChange={(event) => setReason(event.target.value)}
            placeholder="Ej: el cliente devolvió la mercadería"
            rows={3}
            aria-required="true"
            className="bg-background border-border text-foreground"
          />
          <p className="text-xs text-muted-foreground">Entre {REASON_MIN} y {REASON_MAX} caracteres. Queda en el historial.</p>
        </div>
        <div className="flex flex-col-reverse gap-2 sm:flex-row sm:justify-end">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={submitting}>
            Volver
          </Button>
          <Button type="submit" variant="destructive" disabled={!reasonValid || submitting}>
            {submitting ? "Anulando…" : "Anular remito"}
          </Button>
        </div>
      </form>
    </ResponsiveModal>
  )
}
