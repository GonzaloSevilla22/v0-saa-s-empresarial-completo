"use client"

/**
 * OperationEditPlanDialog — la confirmación de una edición que toca dinero
 * (edicion-operaciones-con-dinero, tanda C, D13/D17).
 *
 * Muestra el PLAN que calculó el servidor con la misma función que ejecuta la edición (`POST .../edit-preview`): por libro
 * —cuenta corriente, caja, banco— qué se compensa y qué se registra, con el sentido real del dinero ("entran" o "salen" de la
 * caja). La interfaz no recalcula nada: lo que se ve sale de la respuesta. Con un bloqueo de negocio la confirmación queda
 * deshabilitada y el motivo visible ("Abrí la caja…", "Anulá primero el cobro…"); si el plan no cambia ningún libro el
 * diálogo no aparece (el formulario guarda directo, ver `planNeedsConfirmation`).
 *
 * Es CONTROLADO: el formulario lo abre con el plan en la mano y decide qué hace al confirmar. Se abre por estado (lo dispara el
 * submit, no hay un trigger), y Radix sólo sabe devolver el foco a un trigger que no existe: al cerrar, el foco se devuelve
 * a mano al control que lo abrió (`returnFocusRef`), el mismo criterio de `venta-editable-sin-cae`.
 */

import { useId } from "react"
import type { RefObject } from "react"
import {
  AlertDialog, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { MoneyPlanList } from "@/components/shared/MoneyPlanList"
import {
  describeBlock,
  moneyPlanItems,
  planNeedsConfirmation,
  voidedFiscalText,
  type EditPreview,
  type MoneyPlanContext,
  type MoneyPlanItem,
} from "@/lib/money-plan"
import { AlertCircle } from "lucide-react"

interface OperationEditPlanDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** La respuesta del servidor a la vista previa; `null` mientras se calcula (no se muestra nada). */
  preview: EditPreview | null
  party: MoneyPlanContext["party"]
  /** Cómo se nombra la operación en el título: "esta venta", "esta compra", "este gasto". */
  documentLabel: string
  onConfirm: () => void
  /** Se está ejecutando la edición real. */
  executing?: boolean
  /** El control que abrió el diálogo: al cerrarlo, el foco vuelve ahí. */
  returnFocusRef?: RefObject<HTMLElement | null>
}

export function OperationEditPlanDialog({
  open, onOpenChange, preview, party, documentLabel, onConfirm, executing = false, returnFocusRef,
}: OperationEditPlanDialogProps) {
  const blockedId = useId()
  if (!preview || !planNeedsConfirmation(preview)) return null

  const items: MoneyPlanItem[] = [
    ...(preview.voided_fiscal_document
      ? [{ book: "fiscal" as const, text: voidedFiscalText(preview.voided_fiscal_document.label) }]
      : []),
    ...moneyPlanItems(preview.plan, { party }),
  ]
  const blocks = preview.plan.blocks
  const blocked = blocks.length > 0

  return (
    <AlertDialog open={open} onOpenChange={onOpenChange}>
      <AlertDialogContent
        className="bg-card border-border max-h-[85dvh] overflow-y-auto"
        onClick={(e) => e.stopPropagation()}
        onCloseAutoFocus={(event) => {
          if (!returnFocusRef) return
          event.preventDefault()
          returnFocusRef.current?.focus()
        }}
      >
        <AlertDialogHeader>
          <AlertDialogTitle className="text-card-foreground">
            ¿Guardar los cambios de {documentLabel}?
          </AlertDialogTitle>
          <AlertDialogDescription asChild>
            <div className="space-y-2 text-left text-sm text-muted-foreground">
              <p>Esto es lo que va a pasar con el dinero de la operación:</p>
              <MoneyPlanList title="Se va a ajustar:" items={items} />
              {blocked && (
                <div
                  id={blockedId}
                  role="alert"
                  className="flex gap-2 rounded-md border border-destructive/30 bg-destructive/10 p-3 text-destructive"
                >
                  <AlertCircle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
                  <div className="space-y-1">
                    <p className="font-medium">No se puede guardar todavía</p>
                    <ul className="list-disc space-y-1 pl-4">
                      {blocks.map((block) => (
                        <li key={`${block.token}-${block.book}`}>{describeBlock(block, { party })}</li>
                      ))}
                    </ul>
                  </div>
                </div>
              )}
            </div>
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel className="border-border text-foreground">Volver a editar</AlertDialogCancel>
          {/* Un Button y no AlertDialogAction: éste cierra el diálogo al hacer clic, y mientras se ejecuta la edición el
              plan tiene que seguir a la vista (el cierre lo decide quien lo abrió). */}
          <Button
            type="button"
            onClick={onConfirm}
            disabled={blocked || executing}
            aria-describedby={blocked ? blockedId : undefined}
          >
            {executing ? "Guardando…" : "Confirmar y guardar"}
          </Button>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
