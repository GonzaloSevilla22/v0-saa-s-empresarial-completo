"use client"

/**
 * DeleteOperationDialog — delete-guard-ledgers (D10, task 9.3/9.4).
 *
 * Reemplaza el `confirm()` nativo ("¿Eliminar esta venta? Esta acción no se
 * puede deshacer.") en sale-operations-list.tsx y purchase-operations-list.tsx
 * por un diálogo del design system que:
 *   - Cuando la operación NO es borrable (comprobante fiscal emitido): el
 *     control aparece deshabilitado con la razón visible — mismo patrón
 *     visual que el lock de edición (Lock icon + title/aria-label).
 *   - Cuando SÍ es borrable pero tiene dinero posteado: enumera qué se va a
 *     compensar en cada libro antes de pedir confirmación.
 *   - Cuando no tiene dinero posteado: confirma sin enumerar (task 9.5).
 *
 * Reutilizado por ambos listados — un solo componente, sin lógica de
 * negocio propia (getDeleteCompensation en lib/delete-compensation.ts ya
 * resolvió todo lo que hay que mostrar).
 *
 * cobranzas-reverso (task 13.3): el vocabulario ("Eliminar"/Trash2) es
 * configurable vía `actionVerb`/`actionVerbGerund`/`icon` — con sus
 * defaults ORIGINALES, para no tocar el comportamiento de los tres
 * consumidores existentes (venta/compra/gasto). La anulación de un cobro/
 * pago de cuenta corriente reutiliza este mismo componente con "Anular"/
 * RotateCcw: es la MISMA estructura (bloqueado con razón / enumeración de
 * compensaciones / confirmar), sólo cambia el verbo — reutilización real,
 * no una copia con otro nombre.
 */

import { Button } from "@/components/ui/button"
import {
  AlertDialog, AlertDialogAction, AlertDialogCancel, AlertDialogContent,
  AlertDialogDescription, AlertDialogFooter, AlertDialogHeader, AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { Lock, Trash2 } from "lucide-react"
import type { DeleteCompensationInfo } from "@/lib/delete-compensation"

interface DeleteOperationDialogProps {
  /** Texto que identifica la operación en el título ("esta venta", "esta operación (3 ítems)"). */
  label: string
  info: DeleteCompensationInfo
  onConfirm: () => void
  isDeleting: boolean
  /** Detiene la propagación del click del trigger — el botón vive dentro de
   * una fila clickeable que expande/colapsa el detalle. */
  onTriggerClick?: (e: React.MouseEvent) => void
  /** cobranzas-reverso: verbo de la acción, infinitivo. Default "Eliminar"
   * — preserva el comportamiento de los consumidores existentes. */
  actionVerb?: string
  /** Gerundio para el estado "en curso" del botón de confirmación. Default "Eliminando". */
  actionVerbGerund?: string
  /** Ícono del trigger. Default Trash2. */
  icon?: React.ReactNode
  /** cobranzas-reverso (task 13.3, OQ-2 apply): campo de motivo OPCIONAL —
   * visible en el diálogo, controlado por el padre. Ausente en los tres
   * consumidores existentes (venta/compra/gasto no lo piden). */
  reasonField?: {
    value: string
    onChange: (value: string) => void
    label?: string
  }
}

export function DeleteOperationDialog({
  label, info, onConfirm, isDeleting, onTriggerClick,
  actionVerb = "Eliminar", actionVerbGerund = "Eliminando", icon, reasonField,
}: DeleteOperationDialogProps) {
  const triggerIcon = icon ?? <Trash2 className="h-3.5 w-3.5" />

  if (!info.deletable) {
    return (
      <Button
        type="button"
        variant="ghost"
        size="icon"
        disabled
        title={info.blockedReason ?? undefined}
        aria-label={info.blockedReason ?? `No se puede ${actionVerb.toLowerCase()}`}
        className="h-8 w-8 text-muted-foreground/50"
        data-testid="delete-operation-blocked"
      >
        <Lock className="h-3.5 w-3.5" />
      </Button>
    )
  }

  return (
    <AlertDialog>
      <AlertDialogTrigger asChild>
        <Button
          type="button"
          variant="ghost"
          size="icon"
          onClick={onTriggerClick}
          disabled={isDeleting}
          className="h-8 w-8 text-muted-foreground hover:text-destructive hover:bg-destructive/10"
          data-testid="delete-operation-trigger"
          aria-label={`${actionVerb} ${label}`}
        >
          {triggerIcon}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent className="bg-card border-border" onClick={(e) => e.stopPropagation()}>
        <AlertDialogHeader>
          <AlertDialogTitle className="text-card-foreground">
            ¿{actionVerb} {label}?
          </AlertDialogTitle>
          <AlertDialogDescription asChild>
            <div className="space-y-2 text-sm text-muted-foreground">
              <p>Esta acción no se puede deshacer.</p>
              {info.compensations.length > 0 && (
                <div className="rounded-md border border-border bg-accent/30 p-3">
                  <p className="mb-1.5 font-medium text-foreground">Se va a compensar:</p>
                  <ul className="list-disc space-y-1 pl-4">
                    {info.compensations.map((item) => (
                      <li key={item}>{item}</li>
                    ))}
                  </ul>
                </div>
              )}
              {reasonField && (
                <div className="space-y-1.5 pt-1">
                  <Label htmlFor="delete-operation-reason" className="text-foreground">
                    {reasonField.label ?? "Motivo (opcional)"}
                  </Label>
                  <Textarea
                    id="delete-operation-reason"
                    value={reasonField.value}
                    onChange={(e) => reasonField.onChange(e.target.value)}
                    onClick={(e) => e.stopPropagation()}
                    placeholder="Ej: importe cargado por error"
                    className="min-h-16 bg-background border-border text-foreground"
                  />
                </div>
              )}
            </div>
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel className="border-border text-foreground">
            Cancelar
          </AlertDialogCancel>
          <AlertDialogAction
            onClick={onConfirm}
            disabled={isDeleting}
            className="bg-destructive text-destructive-foreground hover:bg-destructive/90"
          >
            {isDeleting ? `${actionVerbGerund}…` : actionVerb}
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  )
}
