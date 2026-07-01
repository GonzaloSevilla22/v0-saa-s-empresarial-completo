"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Loader2 } from "lucide-react"
import { toast } from "sonner"
import { useRegisterPayment } from "@/hooks/data/use-customer-account"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"

// bank-payment-routing C2: taxonomía { cash, transfer, card, check }.
const PAYMENT_METHODS = [
  { value: "cash",     label: "Efectivo" },
  { value: "transfer", label: "Transferencia" },
  { value: "card",     label: "Tarjeta" },
  { value: "check",    label: "Cheque" },
] as const

const BANK_METHODS = new Set(["transfer", "card", "check"])

const schema = z
  .object({
    amount: z
      .string()
      .min(1, "Ingresá el importe")
      .refine((v) => !isNaN(Number(v)) && Number(v) > 0, {
        message: "El importe debe ser mayor a 0",
      }),
    paymentMethod: z.enum(["cash", "transfer", "card", "check"]),
    bankAccountId: z.string().optional(),
  })
  .refine(
    (data) => !BANK_METHODS.has(data.paymentMethod) || !!data.bankAccountId,
    { message: "Elegí una cuenta bancaria para este método de pago", path: ["bankAccountId"] }
  )

type FormValues = z.infer<typeof schema>

interface RegisterPaymentFormProps {
  clientId: string
  onSuccess?: () => void
}

export function RegisterPaymentForm({ clientId, onSuccess }: RegisterPaymentFormProps) {
  const [submitting, setSubmitting] = useState(false)
  const { mutateAsync: registerPayment } = useRegisterPayment(clientId)
  const { data: bankAccounts, isLoading: bankAccountsLoading } = useBankAccounts()

  const {
    register,
    handleSubmit,
    reset,
    watch,
    setValue,
    formState: { errors },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
    defaultValues: { paymentMethod: "cash" },
  })

  const paymentMethod = watch("paymentMethod")
  const isBankMethod = BANK_METHODS.has(paymentMethod)

  async function onSubmit(values: FormValues) {
    setSubmitting(true)
    try {
      const idempotencyKey = `pay-${clientId}-${Date.now()}`
      const result = await registerPayment({
        idempotencyKey,
        amount: Number(values.amount),
        paymentMethod: values.paymentMethod,
        bankAccountId: isBankMethod ? values.bankAccountId : undefined,
      })
      if (result.replayed) {
        toast.info("Cobro ya registrado (idempotente)")
      } else {
        toast.success("Cobro registrado correctamente")
      }
      reset({ paymentMethod: "cash" })
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

      <div className="space-y-1.5">
        <Label htmlFor="payment-method" className="text-sm text-foreground">
          Método de pago
        </Label>
        <Select
          value={paymentMethod}
          onValueChange={(v) => setValue("paymentMethod", v as FormValues["paymentMethod"])}
        >
          <SelectTrigger id="payment-method" className="bg-background border-border text-foreground">
            <SelectValue />
          </SelectTrigger>
          <SelectContent>
            {PAYMENT_METHODS.map((m) => (
              <SelectItem key={m.value} value={m.value}>
                {m.label}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      {isBankMethod && (
        <div className="space-y-1.5">
          <Label htmlFor="bank-account" className="text-sm text-foreground">
            Cuenta bancaria
          </Label>
          <Select
            value={watch("bankAccountId") ?? ""}
            onValueChange={(v) => setValue("bankAccountId", v)}
            disabled={bankAccountsLoading}
          >
            <SelectTrigger id="bank-account" className="bg-background border-border text-foreground">
              <SelectValue placeholder="Elegí una cuenta bancaria" />
            </SelectTrigger>
            <SelectContent>
              {(bankAccounts ?? []).map((ba) => (
                <SelectItem key={ba.id} value={ba.id}>
                  {ba.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
          {errors.bankAccountId && (
            <p className="text-xs text-destructive">{errors.bankAccountId.message}</p>
          )}
        </div>
      )}

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
