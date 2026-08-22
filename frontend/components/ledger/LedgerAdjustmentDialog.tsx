"use client"

/**
 * LedgerAdjustmentDialog — diálogo compartido de ajuste manual para Caja y
 * Banco (ledger-adjustment, D9 del design).
 *
 * Importe con signo explícito: radio Sobrante(+)/Faltante(−) + monto
 * absoluto, para que nadie tenga que acordarse del signo. Motivo obligatorio
 * (Zod en el cliente — el CHECK de la DB es la autoridad final, D9: el
 * cliente no reemplaza al servidor). Advertencia de irreversibilidad antes
 * de confirmar. En modo banco suma `value_date` (default hoy) e
 * `Idempotency-Key`; en modo caja exige sesión abierta y lo dice en el
 * propio diálogo si no la hay.
 */

import { useForm, Controller } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { AlertTriangle, Loader2 } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group"
import { Alert, AlertDescription } from "@/components/ui/alert"
import {
  Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle,
} from "@/components/ui/dialog"

const adjustmentFormSchema = z.object({
  direction: z.enum(["surplus", "shortage"]),
  amount: z.coerce.number().positive("El importe debe ser mayor a 0"),
  description: z.string().trim().min(1, "El motivo es obligatorio"),
  valueDate: z.string().optional(),
})

export type AdjustmentFormValues = z.infer<typeof adjustmentFormSchema>

interface LedgerAdjustmentDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** "cash" oculta value_date (usa la fecha de la sesión); "bank" lo muestra. */
  mode: "cash" | "bank"
  /** false en modo cash cuando no hay sesión abierta — bloquea el submit y lo explica. */
  canSubmit: boolean
  disabledReason?: string
  isSubmitting: boolean
  onConfirm: (values: { amount: number; description: string; valueDate?: string }) => Promise<void>
}

export function LedgerAdjustmentDialog({
  open,
  onOpenChange,
  mode,
  canSubmit,
  disabledReason,
  isSubmitting,
  onConfirm,
}: LedgerAdjustmentDialogProps) {
  const {
    register,
    control,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<AdjustmentFormValues>({
    resolver: zodResolver(adjustmentFormSchema),
    defaultValues: {
      direction: "surplus",
      amount: 0,
      description: "",
      valueDate: new Date().toISOString().slice(0, 10),
    },
  })

  async function onSubmit(values: AdjustmentFormValues) {
    const signedAmount = values.direction === "surplus" ? values.amount : -values.amount
    try {
      await onConfirm({
        amount: signedAmount,
        description: values.description,
        valueDate: mode === "bank" ? values.valueDate : undefined,
      })
      toast.success("Ajuste registrado")
      reset()
      onOpenChange(false)
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "No se pudo registrar el ajuste")
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Registrar ajuste</DialogTitle>
          <DialogDescription>
            Consolidá el saldo del sistema contra el efectivo/extracto real. No es una corrección de
            una operación — si el error está en una venta o compra, editá esa operación en vez de ajustar acá.
          </DialogDescription>
        </DialogHeader>

        {!canSubmit && disabledReason && (
          <Alert variant="destructive">
            <AlertTriangle className="h-4 w-4" />
            <AlertDescription>{disabledReason}</AlertDescription>
          </Alert>
        )}

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 pt-1">
          <div className="space-y-2">
            <Label>Tipo de ajuste</Label>
            <Controller
              control={control}
              name="direction"
              render={({ field }) => (
                <RadioGroup value={field.value} onValueChange={field.onChange} className="flex gap-4">
                  <label className="flex items-center gap-2 text-sm">
                    <RadioGroupItem value="surplus" id="adj-surplus" />
                    Sobrante (+)
                  </label>
                  <label className="flex items-center gap-2 text-sm">
                    <RadioGroupItem value="shortage" id="adj-shortage" />
                    Faltante (−)
                  </label>
                </RadioGroup>
              )}
            />
          </div>

          <div className="space-y-1">
            <Label htmlFor="adj-amount">Importe (valor absoluto)</Label>
            <Input id="adj-amount" type="number" step="0.01" min="0" {...register("amount")} />
            {errors.amount && <p className="text-xs text-destructive">{errors.amount.message}</p>}
          </div>

          {mode === "bank" && (
            <div className="space-y-1">
              <Label htmlFor="adj-value-date">Fecha</Label>
              <Input id="adj-value-date" type="date" {...register("valueDate")} />
            </div>
          )}

          <div className="space-y-1">
            <Label htmlFor="adj-description">Motivo *</Label>
            <Textarea
              id="adj-description"
              placeholder="Ej: sobrante detectado en el conteo del mediodía"
              {...register("description")}
            />
            {errors.description && (
              <p className="text-xs text-destructive">{errors.description.message}</p>
            )}
          </div>

          <Alert>
            <AlertTriangle className="h-4 w-4" />
            <AlertDescription>
              El ajuste es <strong>irreversible</strong> y queda registrado con motivo y autor. Un ajuste
              equivocado se corrige con otro ajuste, nunca se edita ni se borra.
            </AlertDescription>
          </Alert>

          <DialogFooter>
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isSubmitting}>
              Cancelar
            </Button>
            <Button type="submit" disabled={isSubmitting || !canSubmit}>
              {isSubmitting && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Confirmar ajuste
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
