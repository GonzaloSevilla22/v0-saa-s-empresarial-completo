"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Loader2 } from "lucide-react"
import { toast } from "sonner"
import { useRegisterPayment } from "@/hooks/data/use-customer-account"

const schema = z.object({
  amount: z
    .string()
    .min(1, "Ingresá el importe")
    .refine((v) => !isNaN(Number(v)) && Number(v) > 0, {
      message: "El importe debe ser mayor a 0",
    }),
})

type FormValues = z.infer<typeof schema>

interface RegisterPaymentFormProps {
  clientId: string
  onSuccess?: () => void
}

export function RegisterPaymentForm({ clientId, onSuccess }: RegisterPaymentFormProps) {
  const [submitting, setSubmitting] = useState(false)
  const { mutateAsync: registerPayment } = useRegisterPayment(clientId)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
  })

  async function onSubmit(values: FormValues) {
    setSubmitting(true)
    try {
      const idempotencyKey = `pay-${clientId}-${Date.now()}`
      const result = await registerPayment({
        idempotencyKey,
        amount: Number(values.amount),
      })
      if (result.replayed) {
        toast.info("Cobro ya registrado (idempotente)")
      } else {
        toast.success("Cobro registrado correctamente")
      }
      reset()
      onSuccess?.()
    } catch (err) {
      toast.error((err as Error).message || "Error al registrar el cobro")
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
      <div className="space-y-1.5">
        <Label htmlFor="amount" className="text-sm text-foreground">
          Importe del cobro (ARS)
        </Label>
        <div className="relative">
          <span className="absolute left-3 top-1/2 -translate-y-1/2 text-muted-foreground text-sm pointer-events-none">
            $
          </span>
          <Input
            id="amount"
            type="number"
            step="0.01"
            min="0.01"
            placeholder="0.00"
            className="pl-7 bg-background border-border text-foreground"
            {...register("amount")}
          />
        </div>
        {errors.amount && (
          <p className="text-xs text-destructive">{errors.amount.message}</p>
        )}
      </div>

      <Button
        type="submit"
        disabled={submitting}
        className="w-full"
        size="sm"
      >
        {submitting ? (
          <>
            <Loader2 className="h-4 w-4 mr-2 animate-spin" />
            Registrando...
          </>
        ) : (
          "Registrar cobro"
        )}
      </Button>
    </form>
  )
}
