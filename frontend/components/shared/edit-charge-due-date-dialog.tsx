"use client"

/**
 * EditChargeDueDateDialog — cobranzas-vencimientos OQ-1.
 *
 * Diálogo compartido por CustomerAccountHistory y SupplierAccountHistory
 * para corregir el vencimiento de un cargo (venta/compra a crédito) abierto
 * — hasta este change la única salida para un vencimiento mal cargado era
 * borrar la operación y rehacerla (la operación con cargo posteado es
 * inmutable, P0423). Un solo componente, sin lógica de negocio propia: el
 * padre decide CUÁNDO ofrecerlo (owner/admin + cargo abierto) y pasa
 * onConfirm (la mutación ya resuelta contra el endpoint correcto).
 *
 * Fecha con <Input type="date"> — mismo control nativo que usa el
 * vencimiento del formulario de venta (sale-form.tsx), no un Calendar
 * popover. Vaciar el campo y confirmar limpia el vencimiento (dueDate=null,
 * nunca un error — mismo criterio que CollectionSettingsIn).
 */

import { useState } from "react"
import { CalendarClock, Loader2 } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog"
import { humanizeOperationError } from "@/lib/operation-errors"

interface EditChargeDueDateDialogProps {
  /** Vencimiento actual del cargo, ISO (yyyy-mm-dd) o null (sin vencimiento). */
  currentDueDate: string | null
  onConfirm: (values: { dueDate: string | null; reason?: string }) => Promise<void>
}

export function EditChargeDueDateDialog({ currentDueDate, onConfirm }: EditChargeDueDateDialogProps) {
  const [open, setOpen] = useState(false)
  const [dueDate, setDueDate] = useState(currentDueDate ?? "")
  const [reason, setReason] = useState("")
  const [isSubmitting, setIsSubmitting] = useState(false)

  function handleOpenChange(v: boolean) {
    if (v) {
      // Reabrir siempre parte del valor VIGENTE del cargo — nunca de un
      // borrador anterior descartado.
      setDueDate(currentDueDate ?? "")
      setReason("")
    }
    setOpen(v)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    setIsSubmitting(true)
    try {
      await onConfirm({ dueDate: dueDate || null, reason: reason || undefined })
      toast.success("Vencimiento actualizado")
      setOpen(false)
    } catch (err) {
      // El diálogo queda ABIERTO en un error — el usuario puede corregir el
      // valor y reintentar (mismo criterio que LedgerAdjustmentDialog).
      const { message } = humanizeOperationError((err as Error).message)
      toast.error(message)
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogTrigger asChild>
        <Button
          type="button"
          variant="ghost"
          size="icon"
          onClick={(e) => e.stopPropagation()}
          className="h-8 w-8 text-muted-foreground hover:text-foreground hover:bg-accent"
          data-testid="edit-charge-due-date-trigger"
          aria-label="Editar vencimiento"
        >
          <CalendarClock className="h-3.5 w-3.5" />
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-sm" onClick={(e) => e.stopPropagation()}>
        <DialogHeader>
          <DialogTitle>Editar vencimiento</DialogTitle>
          <DialogDescription>
            Corrige el vencimiento de este cargo sin tener que borrar y rehacer la operación.
          </DialogDescription>
        </DialogHeader>
        <form onSubmit={handleSubmit} className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="charge-due-date">Vencimiento</Label>
            <Input
              id="charge-due-date"
              type="date"
              value={dueDate}
              onChange={(e) => setDueDate(e.target.value)}
            />
            <p className="text-xs text-muted-foreground">
              Dejalo vacío para que el cargo quede sin vencimiento.
            </p>
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="charge-due-date-reason">Motivo (opcional)</Label>
            <Textarea
              id="charge-due-date-reason"
              value={reason}
              onChange={(e) => setReason(e.target.value)}
              placeholder="Ej: vencimiento cargado por error"
              className="min-h-16"
            />
          </div>
          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => handleOpenChange(false)} disabled={isSubmitting}>
              Cancelar
            </Button>
            <Button type="submit" disabled={isSubmitting}>
              {isSubmitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Guardar
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
