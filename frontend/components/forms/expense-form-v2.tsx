"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Checkbox } from "@/components/ui/checkbox"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useAddExpense, useUpdateExpense } from "@/hooks/data/use-expenses-query"
import { EXPENSE_CATEGORIES } from "@/lib/constants"
import { AlertCircle, CalendarIcon } from "lucide-react"
import { toast } from "sonner"
import { bankAccountForKind, isBankPaymentKind, type Expense } from "@/lib/types"
import { BranchSelect } from "@/components/branches/BranchSelect"
import { CostCenterSelect } from "@/components/cost-centers/CostCenterSelect"
import {
  PaymentMethodSelect,
  BankAccountDestinationSelect,
} from "@/components/payment-methods/PaymentMethodSelect"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"
import { useCashOptin } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"

interface ExpenseFormProps {
  onSuccess: () => void
  /** When provided, the form opens in edit mode pre-filled with these values. */
  initialData?: Expense
}

export function ExpenseForm({ onSuccess, initialData }: ExpenseFormProps) {
  const addExpenseMutation    = useAddExpense()
  const updateExpenseMutation = useUpdateExpense()
  const isEdit = !!initialData

  const [category,      setCategory]      = useState(initialData?.category      ?? "")
  const [description,   setDescription]   = useState(initialData?.description   ?? "")
  const [amount,        setAmount]        = useState(initialData?.amount         ?? 0)
  const [date,          setDate]          = useState(initialData?.date           ?? argentinaToday())
  const [branchId,      setBranchId]      = useState<string | null>(initialData?.branchId      ?? null)
  const [costCenterId,  setCostCenterId]  = useState<string | null>(initialData?.costCenterId  ?? null)
  // ── gastos-forma-pago ─────────────────────────────────────────────────────
  const [paymentMethodId, setPaymentMethodId] = useState<string | null>(initialData?.paymentMethodId ?? null)
  // D5: override de la cuenta bancaria de origen. Sólo en el alta — la edición
  // no postea movimientos (D11), así que `rpc_update_expense` ni lo recibe.
  const [bankAccountId, setBankAccountId] = useState<string | null>(null)
  /**
   * D1 / OQ-1 firmada por el PO: el opt-in de caja arranca PRE-MARCADO, al
   * revés que el formulario de venta. La asimetría es deliberada: la venta
   * arranca desmarcada por 223 operaciones históricas y el hábito de cargar
   * ventas retroactivas; el gasto no tiene esa deuda (0 de 175 tocaron caja
   * jamás) y el pedido del PO es literalmente que concilien caja.
   */
  const [registerInCash, setRegisterInCash] = useState(true)

  // El `kind` se resuelve del catálogo, nunca se escribe a mano.
  const { paymentMethods } = usePaymentMethods(isEdit)
  const resolvedKind = paymentMethods.find((pm) => pm.id === paymentMethodId)?.kind ?? null

  // D5: la exigencia de cuenta bancaria es CONDICIONAL a que la organización
  // tenga alguna activa — el mismo criterio que la RPC. Sin esto, 33 de 37
  // tenants no podrían registrar un gasto por transferencia.
  const { data: bankAccounts } = useBankAccounts()
  const hasActiveBankAccounts = (bankAccounts ?? []).some((b) => b.isActive)
  const bankAccountRequired = !isEdit && isBankPaymentKind(resolvedKind) && hasActiveBankAccounts

  // D16: mismo hook que el formulario de venta — las tres condiciones no se
  // reescriben, se reusan.
  const cashOptin = useCashOptin({ kind: resolvedKind, branchId, date, document: "gasto" })
  const showCashBlock = !isEdit && cashOptin.isCashSelected

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!category || !description) {
      toast.error("Completá todos los campos")
      return
    }
    // El importe gobierna dinero real: la caja postea `-importe` y el banco un
    // egreso, así que un importe no positivo invertiría el efecto en libros.
    // El servidor es la autoridad (P0400 en la RPC + CHECK en la tabla); acá se
    // avisa con el motivo para que el usuario no coma un error crudo — el
    // `min={0}` del input deja pasar el cero, y NumericInput manda 0 cuando el
    // campo queda vacío.
    if (!(amount > 0)) {
      toast.error("El monto tiene que ser mayor a cero")
      return
    }
    // Se avisa acá para que el usuario no coma el P0412 del servidor, que es
    // la autoridad real (422 con field = bank_account_id).
    if (bankAccountRequired && !bankAccountId) {
      toast.error("Elegí la cuenta bancaria de la que sale el dinero")
      return
    }
    try {
      if (isEdit && initialData) {
        // Tri-estado por presencia de la clave: el formulario controla los
        // tres campos, así que los tres viajan siempre (D12).
        await updateExpenseMutation.mutateAsync({
          ...initialData, category, description, amount, date,
          costCenterId, branchId, paymentMethodId,
        })
        toast.success("Gasto actualizado")
      } else {
        await addExpenseMutation.mutateAsync({
          date, category, description, amount, branchId, costCenterId,
          paymentMethodId,
          // Sólo cuando las tres condiciones se cumplen Y el usuario lo dejó
          // tildado. En cualquier otro caso viaja null y la RPC no toca caja.
          cashSessionId: cashOptin.eligible && registerInCash ? (cashOptin.session?.id ?? null) : null,
          // Bug prod 2026-08-24: el selector se desmonta al cambiar de kind
          // pero el useState conserva el valor — bankAccountForKind lo limpia.
          bankAccountId: bankAccountForKind(resolvedKind, bankAccountId),
        })
        toast.success("Gasto registrado")
      }
      onSuccess()
    } catch (error: unknown) {
      console.error("Expense form error:", error)
      const errorMsg =
        error instanceof Error ? error.message : typeof error === "string" ? error : "Error desconocido"
      toast.error(`Error al ${isEdit ? "actualizar" : "registrar"} gasto: ${errorMsg}`)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label htmlFor="expense-category" className="text-foreground">Categoría</Label>
        <Select value={category} onValueChange={setCategory}>
          <SelectTrigger id="expense-category" className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar categoría" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {EXPENSE_CATEGORIES.map((c) => (
              <SelectItem key={c} value={c}>{c}</SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label htmlFor="expense-description" className="text-foreground">Descripción</Label>
        <Input
          id="expense-description"
          selectOnFocus
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Detalle del gasto"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label htmlFor="expense-amount" className="text-foreground">Monto</Label>
          <NumericInput
            id="expense-amount"
            min={0}
            step={0.01}
            value={amount}
            onValueChange={setAmount}
            className="bg-background border-border text-foreground"
          />
        </div>

        <div className="flex flex-col gap-2">
          <Label htmlFor="expense-date" className="text-foreground flex items-center gap-1.5">
            <CalendarIcon className="h-3.5 w-3.5 text-muted-foreground" />
            Fecha
          </Label>
          <input
            id="expense-date"
            type="date"
            value={date}
            max={argentinaToday()}
            onChange={(e) => setDate(e.target.value)}
            className="flex h-10 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          />
        </div>
      </div>

      {/* ── Forma de pago (gastos-forma-pago) ─────────────────────── */}
      <PaymentMethodSelect
        value={paymentMethodId}
        onChange={setPaymentMethodId}
        context="expense"
        // En edición hay que poder seguir nombrando una forma dada de baja.
        includeInactive={isEdit}
        className="bg-background border-border text-foreground text-sm"
      />

      {/* ── Cuenta bancaria de origen (D5, obligatoria en el alta) ── */}
      {!isEdit && (
        <BankAccountDestinationSelect
          paymentMethodKind={resolvedKind}
          value={bankAccountId}
          onChange={setBankAccountId}
          required
          showEmptyNotice
          className="bg-background border-border text-foreground text-sm"
        />
      )}

      {/* ── Opt-in de caja (D1, pre-marcado — OQ-1) ────────────────
          Las tres condiciones las verifica el servidor; acá se muestran para
          que el usuario no descubra el bloqueo con un error. Cuando no
          aplican, el motivo se muestra: nunca se oculta en silencio. */}
      {showCashBlock && (
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

      {/* ── Sucursal (solo plan PRO) ───────────────────────────────── */}
      <BranchSelect
        value={branchId}
        onChange={setBranchId}
        placeholder="Sin sucursal (general)"
        className="bg-background border-border text-foreground text-sm"
      />

      {/* ── Centro de costo (opcional, V2.5) ──────────────────────── */}
      <CostCenterSelect
        value={costCenterId}
        onChange={setCostCenterId}
        className="bg-background border-border text-foreground text-sm"
      />

      <Button type="submit" className="w-full">
        {isEdit ? "Guardar cambios" : "Registrar gasto"}
      </Button>
    </form>
  )
}
