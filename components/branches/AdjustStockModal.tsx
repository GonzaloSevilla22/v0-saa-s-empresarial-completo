"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { toast } from "sonner"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogFooter,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Loader2 } from "lucide-react"
import { useAdjustBranchStock } from "@/hooks/data/use-branch-stock"

const schema = z.object({
  newQuantity: z.coerce
    .number({ invalid_type_error: "Ingresá un número válido" })
    .min(0, "La cantidad no puede ser negativa"),
  reason: z
    .string()
    .min(1, "La razón del ajuste es requerida")
    .max(255, "Máximo 255 caracteres"),
})

type FormValues = z.infer<typeof schema>

interface AdjustStockModalProps {
  productId:       string
  branchId:        string
  currentQuantity: number
  productName:     string
  onClose:         () => void
}

export function AdjustStockModal({
  productId,
  branchId,
  currentQuantity,
  productName,
  onClose,
}: AdjustStockModalProps) {
  const [open, setOpen] = useState(true)
  const { mutateAsync: adjust, isPending } = useAdjustBranchStock()

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      newQuantity: currentQuantity,
      reason:      "",
    },
  })

  function handleClose() {
    setOpen(false)
    onClose()
  }

  async function onSubmit(values: FormValues) {
    try {
      await adjust({
        productId,
        branchId,
        newQuantity: values.newQuantity,
        reason:      values.reason,
      })
      toast.success(`Stock de "${productName}" ajustado a ${values.newQuantity}`)
      handleClose()
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al ajustar el stock")
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) handleClose() }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Ajustar stock — {productName}</DialogTitle>
        </DialogHeader>

        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor="currentQuantity" className="text-xs text-muted-foreground">
              Stock actual
            </Label>
            <Input
              id="currentQuantity"
              value={currentQuantity}
              disabled
              className="bg-muted"
            />
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="newQuantity">Nueva cantidad *</Label>
            <Input
              id="newQuantity"
              type="number"
              step="any"
              min={0}
              {...register("newQuantity")}
              aria-invalid={!!errors.newQuantity}
            />
            {errors.newQuantity && (
              <p className="text-xs text-destructive">{errors.newQuantity.message}</p>
            )}
          </div>

          <div className="space-y-1.5">
            <Label htmlFor="reason">Razón del ajuste *</Label>
            <Input
              id="reason"
              type="text"
              placeholder="Ej: Inventario físico, merma, corrección..."
              {...register("reason")}
              aria-invalid={!!errors.reason}
            />
            {errors.reason && (
              <p className="text-xs text-destructive">{errors.reason.message}</p>
            )}
          </div>

          <DialogFooter className="gap-2">
            <Button type="button" variant="outline" onClick={handleClose} disabled={isPending}>
              Cancelar
            </Button>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Ajustar stock
            </Button>
          </DialogFooter>
        </form>
      </DialogContent>
    </Dialog>
  )
}
