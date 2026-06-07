"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { useCreateBranch } from "@/hooks/data/use-branches"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogTrigger,
} from "@/components/ui/dialog"
import { Plus, Loader2 } from "lucide-react"
import { toast } from "sonner"

const schema = z.object({
  name:    z.string().min(1, "El nombre es obligatorio").max(100),
  address: z.string().max(200).optional(),
})
type FormValues = z.infer<typeof schema>

interface BranchFormProps {
  disabled?: boolean
}

export function BranchForm({ disabled }: BranchFormProps) {
  const [open, setOpen] = useState(false)
  const { mutateAsync, isPending } = useCreateBranch()

  const { register, handleSubmit, reset, formState: { errors } } = useForm<FormValues>({
    resolver: zodResolver(schema),
  })

  async function onSubmit(values: FormValues) {
    try {
      await mutateAsync({ name: values.name, address: values.address || undefined })
      toast.success(`Sucursal "${values.name}" creada`)
      reset()
      setOpen(false)
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al crear la sucursal")
    }
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button disabled={disabled} size="sm">
          <Plus className="h-4 w-4 mr-1" />
          Nueva sucursal
        </Button>
      </DialogTrigger>
      <DialogContent className="sm:max-w-sm">
        <DialogHeader>
          <DialogTitle>Crear sucursal</DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 pt-2">
          <div className="space-y-1">
            <Label htmlFor="name">Nombre *</Label>
            <Input id="name" placeholder="Ej: Local Centro" {...register("name")} />
            {errors.name && (
              <p className="text-xs text-destructive">{errors.name.message}</p>
            )}
          </div>
          <div className="space-y-1">
            <Label htmlFor="address">Dirección (opcional)</Label>
            <Input id="address" placeholder="Ej: San Martín 456, Mendoza" {...register("address")} />
          </div>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => setOpen(false)}>
              Cancelar
            </Button>
            <Button type="submit" disabled={isPending}>
              {isPending && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Crear
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
