"use client"

import { useForm } from "react-hook-form"
import { zodResolver } from "@hookform/resolvers/zod"
import { z } from "zod"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle,
} from "@/components/ui/dialog"
import { Loader2 } from "lucide-react"
import { toast } from "sonner"

/**
 * Zod schema for the bank account creation form (bank-account-crud, D5/D4).
 * Mirrors backend/schemas/bank_accounts.py::BankAccountCreate: name requerido;
 * cbu opcional con regex 22 dígitos; currency default ARS; opening_balance >= 0.
 */
export const bankAccountFormSchema = z.object({
  name: z.string().trim().min(1, "El nombre es obligatorio"),
  bank_name: z.string().trim().optional().or(z.literal("")),
  cbu: z
    .string()
    .regex(/^\d{22}$/, "El CBU debe tener exactamente 22 dígitos numéricos")
    .optional()
    .or(z.literal("")),
  alias: z.string().trim().optional().or(z.literal("")),
  currency: z.string().default("ARS"),
  opening_balance: z.coerce.number().min(0, "El saldo inicial no puede ser negativo").default(0),
  opening_date: z.string().optional().or(z.literal("")),
})

export type BankAccountFormValues = z.infer<typeof bankAccountFormSchema>

interface BankAccountFormDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
}

/**
 * Dialog para el alta de cuentas bancarias (bank-account-crud).
 * Disparado desde el empty state y el header de la card en /finanzas/conciliacion (D5).
 * Único Client Component del flujo — RHF + Zod, invalida queryKeys.bankAccounts en éxito.
 */
export function BankAccountFormDialog({ open, onOpenChange }: BankAccountFormDialogProps) {
  const { createBankAccount, createBankAccountMutation } = useBankAccounts()

  const {
    register,
    handleSubmit,
    reset,
    formState: { errors },
  } = useForm<BankAccountFormValues>({
    resolver: zodResolver(bankAccountFormSchema),
    defaultValues: { currency: "ARS", opening_balance: 0 },
  })

  const isSaving = createBankAccountMutation.isPending

  async function onSubmit(values: BankAccountFormValues) {
    try {
      await createBankAccount({
        name: values.name,
        bank_name: values.bank_name || undefined,
        cbu: values.cbu || undefined,
        alias: values.alias || undefined,
        currency: values.currency || "ARS",
        opening_balance: values.opening_balance ?? 0,
        opening_date: values.opening_date || undefined,
      })
      toast.success(`Cuenta "${values.name}" creada`)
      reset()
      onOpenChange(false)
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al crear la cuenta bancaria")
    }
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="sm:max-w-md">
        <DialogHeader>
          <DialogTitle>Nueva cuenta bancaria</DialogTitle>
        </DialogHeader>
        <form onSubmit={handleSubmit(onSubmit)} className="space-y-4 pt-2">
          <div className="space-y-1">
            <Label htmlFor="ba-name">Nombre *</Label>
            <Input id="ba-name" placeholder="Ej: Cuenta corriente Galicia" {...register("name")} />
            {errors.name && <p className="text-xs text-destructive">{errors.name.message}</p>}
          </div>

          <div className="space-y-1">
            <Label htmlFor="ba-bank-name">Banco (opcional)</Label>
            <Input id="ba-bank-name" placeholder="Ej: Banco Galicia" {...register("bank_name")} />
          </div>

          <div className="space-y-1">
            <Label htmlFor="ba-cbu">CBU (opcional)</Label>
            <Input id="ba-cbu" placeholder="22 dígitos" maxLength={22} {...register("cbu")} />
            {errors.cbu && <p className="text-xs text-destructive">{errors.cbu.message}</p>}
          </div>

          <div className="space-y-1">
            <Label htmlFor="ba-alias">Alias (opcional)</Label>
            <Input id="ba-alias" placeholder="Ej: galicia.cuenta" {...register("alias")} />
          </div>

          <div className="grid grid-cols-2 gap-3">
            <div className="space-y-1">
              <Label htmlFor="ba-currency">Moneda</Label>
              <Input id="ba-currency" placeholder="ARS" {...register("currency")} />
            </div>
            <div className="space-y-1">
              <Label htmlFor="ba-opening-balance">Saldo inicial</Label>
              <Input
                id="ba-opening-balance"
                type="number"
                step="0.01"
                placeholder="0"
                {...register("opening_balance")}
              />
              {errors.opening_balance && (
                <p className="text-xs text-destructive">{errors.opening_balance.message}</p>
              )}
            </div>
          </div>

          <div className="space-y-1">
            <Label htmlFor="ba-opening-date">Fecha del saldo inicial (opcional)</Label>
            <Input id="ba-opening-date" type="date" {...register("opening_date")} />
          </div>

          <div className="flex justify-end gap-2 pt-2">
            <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={isSaving}>
              Cancelar
            </Button>
            <Button type="submit" disabled={isSaving}>
              {isSaving && <Loader2 className="mr-2 h-4 w-4 animate-spin" />}
              Crear
            </Button>
          </div>
        </form>
      </DialogContent>
    </Dialog>
  )
}
