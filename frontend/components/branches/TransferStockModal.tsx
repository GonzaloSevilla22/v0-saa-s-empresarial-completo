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
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Loader2 } from "lucide-react"
import { useBranches } from "@/hooks/data/use-branches"
import { useTransferStock } from "@/hooks/data/use-branch-stock"

const schema = z.object({
  toBranchId: z.string().min(1, "Seleccioná una sucursal destino"),
  quantity:   z.coerce
    .number({ invalid_type_error: "Ingresá un número válido" })
    .positive("La cantidad debe ser mayor a cero"),
})

type FormValues = z.infer<typeof schema>

interface TransferStockModalProps {
  productId:       string
  currentBranchId: string
  currentQuantity: number
  productName:     string
  onClose:         () => void
}

export function TransferStockModal({
  productId,
  currentBranchId,
  currentQuantity,
  productName,
  onClose,
}: TransferStockModalProps) {
  const [open, setOpen] = useState(true)
  const { branches, isLoading: branchesLoading } = useBranches()
  const { mutateAsync: transfer, isPending } = useTransferStock()

  // Exclude the current branch from the destination options
  const destinationBranches = branches.filter((b) => b.id !== currentBranchId)

  const {
    register,
    handleSubmit,
    setValue,
    watch,
    formState: { errors },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: {
      toBranchId: "",
      quantity:   1,
    },
  })

  const selectedBranchId = watch("toBranchId")

  function handleClose() {
    setOpen(false)
    onClose()
  }

  async function onSubmit(values: FormValues) {
    try {
      await transfer({
        productId,
        fromBranchId: currentBranchId,
        toBranchId:   values.toBranchId,
        quantity:     values.quantity,
      })
      const destBranch = destinationBranches.find((b) => b.id === values.toBranchId)
      toast.success(
        `Se transfirieron ${values.quantity} unidades de "${productName}" a ${destBranch?.name ?? "la sucursal destino"}`
      )
      handleClose()
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al transferir stock")
    }
  }

  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) handleClose() }}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Transferir stock — {productName}</DialogTitle>
        </DialogHeader>

        {branchesLoading ? (
          <div className="flex items-center justify-center py-8">
            <Loader2 className="h-5 w-5 animate-spin text-muted-foreground" />
          </div>
        ) : destinationBranches.length === 0 ? (
          <p className="text-sm text-muted-foreground py-4 text-center">
            No hay otras sucursales activas para transferir stock.
          </p>
        ) : (
          <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
            <div className="space-y-1.5">
              <Label className="text-xs text-muted-foreground">Stock disponible en esta sucursal</Label>
              <Input value={currentQuantity} disabled className="bg-muted" />
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="toBranchId">Sucursal destino *</Label>
              <Select
                value={selectedBranchId}
                onValueChange={(val) => setValue("toBranchId", val, { shouldValidate: true })}
              >
                <SelectTrigger id="toBranchId" aria-invalid={!!errors.toBranchId}>
                  <SelectValue placeholder="Seleccioná una sucursal" />
                </SelectTrigger>
                <SelectContent>
                  {destinationBranches.map((branch) => (
                    <SelectItem key={branch.id} value={branch.id}>
                      {branch.name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {errors.toBranchId && (
                <p className="text-xs text-destructive">{errors.toBranchId.message}</p>
              )}
            </div>

            <div className="space-y-1.5">
              <Label htmlFor="quantity">Cantidad a transferir *</Label>
              <Input
                id="quantity"
                type="number"
                step="any"
                min={0.0001}
                max={currentQuantity}
                {...register("quantity")}
                aria-invalid={!!errors.quantity}
              />
              {errors.quantity && (
                <p className="text-xs text-destructive">{errors.quantity.message}</p>
              )}
            </div>

            <DialogFooter className="gap-2">
              <Button type="button" variant="outline" onClick={handleClose} disabled={isPending}>
                Cancelar
              </Button>
              <Button type="submit" disabled={isPending}>
                {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
                Transferir
              </Button>
            </DialogFooter>
          </form>
        )}
      </DialogContent>
    </Dialog>
  )
}
