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
 * remitos-compra (D6/D11, tarea 5.3): el diálogo habla del sentido del remito. En
 * compra anular RESTA del stock lo que el remito aportó ("Salen de Sucursal
 * Centro: 10 × Producto A") y el servidor lo rechaza con
 * `delivery_note_stock_consumed` si esa mercadería ya no está (se vendió, se
 * transfirió): el aviso se queda dentro del diálogo, con lo que quedó y las dos
 * salidas ("Editar el remito" para reducirlo a lo que sigue en el depósito, o
 * "Ajustar stock"), en vez de un toast que desaparece. Los textos salen de
 * `DELIVERY_NOTE_TEXTS`, la misma tabla que el detalle.
 *
 * Un error deja el diálogo abierto con el motivo escrito. El foco entra al
 * motivo al abrir; quien lo abrió (`CancelDeliveryNoteDialog` no tiene
 * `Trigger`) lo recupera con `useRestoreFocus` en la página.
 */
import { useEffect, useMemo, useRef, useState } from "react"
import Link from "next/link"
import { PackageMinus, Pencil } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { useCancelDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useProducts } from "@/hooks/data/use-products"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { DELIVERY_NOTE_TEXTS } from "@/lib/delivery-note-status"
import { describeHeldReturn } from "@/lib/delivery-note-stock"
import type { DeliveryNoteApiRow } from "@/lib/delivery-note-types"
import { humanizeOperationError, type OperationErrorAction } from "@/lib/operation-errors"
import { resolveUnit } from "@/lib/unit-utils"

const REASON_MIN = 3
const REASON_MAX = 500

/** El rechazo de una anulación de compra porque la mercadería ya no está toda en la sucursal. */
interface ConsumedNotice {
  message: string
  adjustStock: OperationErrorAction | undefined
}

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
  const [consumed, setConsumed] = useState<ConsumedNotice | null>(null)
  const submittingRef = useRef(false)
  const reasonRef = useRef<HTMLTextAreaElement>(null)

  // Un motivo viejo no sobrevive a una nueva apertura.
  useEffect(() => {
    if (open) {
      setReason("")
      setConsumed(null)
    }
  }, [open])

  // El foco entra al motivo cuando el modal ya está montado (el portal de Radix
  // monta después del primer render).
  useEffect(() => {
    if (!open) return
    const id = window.setTimeout(() => reasonRef.current?.focus(), 0)
    return () => window.clearTimeout(id)
  }, [open])

  const direction = deliveryNote.direction
  const texts = DELIVERY_NOTE_TEXTS[direction]
  const branchName = deliveryNote.branch_name ?? "la sucursal"
  const returnText = useMemo(
    () =>
      describeHeldReturn(
        deliveryNote.items,
        branchName,
        (productId) => resolveUnit(products.find((p) => p.id === productId)?.baseUnitId, unitsById),
        direction,
      ),
    [deliveryNote.items, branchName, products, unitsById, direction],
  )

  const trimmed = reason.trim()
  const reasonValid = trimmed.length >= REASON_MIN && trimmed.length <= REASON_MAX
  const label = deliveryNote.number_label ?? "el remito"

  async function handleSubmit() {
    if (!reasonValid || submittingRef.current) return
    submittingRef.current = true
    setSubmitting(true)
    setConsumed(null)
    try {
      await cancel.mutateAsync({
        deliveryNoteId: deliveryNote.id,
        payload: { reason: trimmed, revision: deliveryNote.revision },
      })
      toast.success(texts.cancelToast(label, branchName))
      onOpenChange(false)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : ""
      const humanized = humanizeOperationError(
        message,
        (productId) => products.find((p) => p.id === productId)?.name,
        null,
        { documentLabel: "remito", direction },
      )
      if (direction === "purchase" && /delivery_note_stock_consumed/.test(message)) {
        setConsumed({ message: humanized.message, adjustStock: humanized.action })
      } else {
        toast.error(humanized.message)
      }
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
          aria-label={direction === "purchase" ? "Stock que sale" : "Stock que vuelve"}
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
            placeholder={texts.cancelReasonPlaceholder}
            rows={3}
            aria-required="true"
            className="bg-background border-border text-foreground"
          />
          <p className="text-xs text-muted-foreground">Entre {REASON_MIN} y {REASON_MAX} caracteres. Queda en el historial.</p>
        </div>
        {consumed && (
          <div
            role="alert"
            aria-label="Mercadería consumida"
            className="flex flex-col gap-2 rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-sm text-foreground"
          >
            <p>{consumed.message}</p>
            <div className="flex flex-wrap gap-x-4 gap-y-1">
              <Link
                href={`/remitos/${deliveryNote.id}/editar`}
                className="inline-flex items-center gap-1 font-medium text-primary underline-offset-2 hover:underline"
              >
                <Pencil className="h-3.5 w-3.5" aria-hidden="true" />
                Editar el remito
              </Link>
              <Link
                href={consumed.adjustStock?.href ?? "/stock"}
                className="inline-flex items-center gap-1 font-medium text-primary underline-offset-2 hover:underline"
              >
                <PackageMinus className="h-3.5 w-3.5" aria-hidden="true" />
                Ajustar stock
              </Link>
            </div>
          </div>
        )}
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
