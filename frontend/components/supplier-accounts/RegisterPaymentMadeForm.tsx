"use client"

import { useState } from "react"
import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Checkbox } from "@/components/ui/checkbox"
import { AlertCircle, Loader2 } from "lucide-react"
import { toast } from "sonner"
import { useRegisterPaymentMade } from "@/hooks/data/use-supplier-account"
import {
  PaymentMethodSelect,
  BankAccountDestinationSelect,
} from "@/components/payment-methods/PaymentMethodSelect"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useCashOptin } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"
import { isBankPaymentKind } from "@/lib/types"

const schema = z.object({
  amount: z
    .string()
    .min(1, "Ingresá el importe")
    .refine((v) => !isNaN(Number(v)) && Number(v) > 0, {
      message: "El importe debe ser mayor a 0",
    }),
})

type FormValues = z.infer<typeof schema>

interface RegisterPaymentMadeFormProps {
  supplierId: string
  onSuccess?: () => void
}

export function RegisterPaymentMadeForm({ supplierId, onSuccess }: RegisterPaymentMadeFormProps) {
  const [submitting, setSubmitting] = useState(false)
  const { mutateAsync: registerPayment } = useRegisterPaymentMade(supplierId)

  // cobranzas-catalogo-pagos (D6): espejo exacto del modal de cobro — mismo
  // contexto "collection", mismo conjunto de opciones.
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(null)
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)
  const { paymentMethods } = usePaymentMethods()
  const resolvedKind = paymentMethods.find((pm) => pm.id === paymentMethodId)?.kind ?? null

  /**
   * caja-compras-cobranzas (D4): espejo exacto de RegisterPaymentForm —
   * arranca PRE-MARCADO.
   */
  const [registerInCash, setRegisterInCash] = useState(true)

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<FormValues>({
    resolver: zodResolver(schema),
  })

  // cobranzas-catalogo-pagos (D11): espejo exacto del modal de cobro — el
  // kind se deriva del catálogo, nunca del valor del control.
  const cashOptin = useCashOptin({
    kind: resolvedKind,
    branchId: null,
    date: argentinaToday(),
    document: "cobro",
    requiresDate: false,
  })

  async function onSubmit(values: FormValues) {
    if (isBankPaymentKind(resolvedKind) && !bankAccountId) {
      toast.error("Elegí la cuenta bancaria de la que sale el dinero")
      return
    }
    setSubmitting(true)
    try {
      const idempotencyKey = `pay-supplier-${supplierId}-${Date.now()}`
      const result = await registerPayment({
        idempotencyKey,
        amount: Number(values.amount),
        paymentMethodId: paymentMethodId ?? undefined,
        bankAccountId: isBankPaymentKind(resolvedKind) ? (bankAccountId ?? undefined) : undefined,
        cashSessionId: cashOptin.eligible && registerInCash ? (cashOptin.session?.id ?? null) : null,
      })
      if (result.replayed) {
        toast.info("Pago ya registrado (idempotente)")
      } else {
        toast.success("Pago al proveedor registrado")
      }
      reset()
      setPaymentMethodId(null)
      setBankAccountId(null)
      setRegisterInCash(true)
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

      {/* ── Forma de pago (cobranzas-catalogo-pagos) ────────────────────── */}
      <PaymentMethodSelect
        value={paymentMethodId}
        onChange={setPaymentMethodId}
        context="collection"
        label="Forma de pago"
        className="bg-background border-border text-foreground"
      />

      {isBankPaymentKind(resolvedKind) && (
        <BankAccountDestinationSelect
          paymentMethodKind={resolvedKind}
          value={bankAccountId}
          onChange={setBankAccountId}
          required
          showEmptyNotice
          className="bg-background border-border text-foreground"
        />
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
