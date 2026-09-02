"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Checkbox } from "@/components/ui/checkbox"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { AlertCircle, Loader2 } from "lucide-react"
import { toast } from "sonner"
import { useRegisterPaymentMade } from "@/hooks/data/use-supplier-account"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"
import { getAccountKindIcon } from "@/lib/bank-account-kind"
import { useCashOptin } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"

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

interface RegisterPaymentMadeFormProps {
  supplierId: string
  onSuccess?: () => void
}

export function RegisterPaymentMadeForm({ supplierId, onSuccess }: RegisterPaymentMadeFormProps) {
  const [submitting, setSubmitting] = useState(false)
  const { mutateAsync: registerPayment } = useRegisterPaymentMade(supplierId)
  const { data: bankAccounts, isLoading: bankAccountsLoading } = useBankAccounts()
  /**
   * caja-compras-cobranzas (D4): espejo exacto de RegisterPaymentForm —
   * arranca PRE-MARCADO.
   */
  const [registerInCash, setRegisterInCash] = useState(true)

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

  // caja-compras-cobranzas (D5): espejo exacto del cobro — document="cobro"
  // (el motivo de fecha nunca se usa, requiresDate=false) y requiresDate=false.
  const cashOptin = useCashOptin({
    kind: paymentMethod,
    branchId: null,
    date: argentinaToday(),
    document: "cobro",
    requiresDate: false,
  })

  async function onSubmit(values: FormValues) {
    setSubmitting(true)
    try {
      const idempotencyKey = `pay-supplier-${supplierId}-${Date.now()}`
      const result = await registerPayment({
        idempotencyKey,
        amount: Number(values.amount),
        paymentMethod: values.paymentMethod,
        bankAccountId: isBankMethod ? values.bankAccountId : undefined,
        cashSessionId: cashOptin.eligible && registerInCash ? (cashOptin.session?.id ?? null) : null,
      })
      if (result.replayed) {
        toast.info("Pago ya registrado (idempotente)")
      } else {
        toast.success("Pago al proveedor registrado")
      }
      reset({ paymentMethod: "cash" })
      onSuccess?.()
    } catch (err) {
      toast.error((err as Error).message || "Error al registrar el pago")
    } finally {
      setSubmitting(false)
    }
  }

  return (
    <form onSubmit={handleSubmit(onSubmit)} className="space-y-4">
      <div className="space-y-1.5">
        <Label htmlFor="amount" className="text-sm text-foreground">
          Importe del pago (ARS)
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
        <Label htmlFor="payment-method-made" className="text-sm text-foreground">
          Método de pago
        </Label>
        <Select
          value={paymentMethod}
          onValueChange={(v) => setValue("paymentMethod", v as FormValues["paymentMethod"])}
        >
          <SelectTrigger id="payment-method-made" className="bg-background border-border text-foreground">
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
          <Label htmlFor="bank-account-made" className="text-sm text-foreground">
            Cuenta bancaria
          </Label>
          <Select
            value={watch("bankAccountId") ?? ""}
            onValueChange={(v) => setValue("bankAccountId", v)}
            disabled={bankAccountsLoading}
          >
            <SelectTrigger id="bank-account-made" className="bg-background border-border text-foreground">
              <SelectValue placeholder="Elegí una cuenta bancaria" />
            </SelectTrigger>
            <SelectContent>
              {(bankAccounts ?? []).map((ba) => {
                const AccountIcon = getAccountKindIcon(ba.accountKind)
                return (
                  <SelectItem key={ba.id} value={ba.id}>
                    <span className="flex items-center gap-1.5">
                      <AccountIcon className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                      {ba.name}
                    </span>
                  </SelectItem>
                )
              })}
            </SelectContent>
          </Select>
          {errors.bankAccountId && (
            <p className="text-xs text-destructive">{errors.bankAccountId.message}</p>
          )}
        </div>
      )}

      {/* ── Opt-in de caja (caja-compras-cobranzas D4, pre-marcado) ─────── */}
      {cashOptin.isCashSelected && (
        <div className="flex flex-col gap-1.5 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs">
          {cashOptin.eligible ? (
            <label className="flex items-center gap-2 cursor-pointer text-foreground">
              <Checkbox
                checked={registerInCash}
                onCheckedChange={(v) => setRegisterInCash(v === true)}
              />
              <span>
                Registrar en caja — sesión {cashOptin.session?.id.slice(0, 8)}…
              </span>
            </label>
          ) : (
            <div role="note" className="flex items-center gap-2 text-muted-foreground">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              <span>{cashOptin.reason}</span>
            </div>
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
          "Registrar pago"
        )}
      </Button>
    </form>
  )
}
