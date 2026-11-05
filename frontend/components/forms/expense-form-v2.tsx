"use client"

import { useCallback, useRef, useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { previewExpenseEdit, useAddExpense, useUpdateExpense } from "@/hooks/data/use-expenses-query"
import { EXPENSE_CATEGORIES } from "@/lib/constants"
import { CalendarIcon } from "lucide-react"
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
import { CashOptinBlock } from "@/components/cash/CashOptinBlock"
import { useCashOptin } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"
import { OperationEditPlanDialog } from "@/components/shared/OperationEditPlanDialog"
import { useEditPlanFlow } from "@/hooks/use-edit-plan-flow"
import { buildEditMoneyIntent } from "@/lib/money-intent"
import { summarizeExecutedPlan } from "@/lib/money-plan"
import { humanizeOperationError } from "@/lib/operation-errors"

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
  // D5: override de la cuenta bancaria de origen.
  // edicion-operaciones-con-dinero (D7): la edición YA compensa y registra en el banco; parte de la cuenta de la huella
  // vigente y SÓLO viaja si el usuario la cambia (`bankTouched`).
  const [bankAccountId, setBankAccountId] = useState<string | null>(() => initialData?.bankAccountId ?? null)
  const [bankTouched, setBankTouched] = useState(false)
  const handleBankAccountChange = useCallback((value: string | null) => {
    setBankAccountId(value)
    setBankTouched(true)
  }, [])
  // edicion-operaciones-con-dinero (D14/D17): motivo opcional del cambio; queda en el historial.
  const [reason, setReason] = useState("")
  /**
   * D1 / OQ-1 firmada por el PO: el opt-in de caja arranca PRE-MARCADO, al
   * revés que el formulario de venta. La asimetría es deliberada: la venta
   * arranca desmarcada por 223 operaciones históricas y el hábito de cargar
   * ventas retroactivas; el gasto no tiene esa deuda (0 de 175 tocaron caja
   * jamás) y el pedido del PO es literalmente que concilien caja.
   */
  // edicion-operaciones-con-dinero (D6): al EDITAR parte de lo que HAY — «Registrado en caja» si el gasto tiene movimiento
  // de caja vigente, desmarcado si no (el pre-marcado es del alta).
  const hadCash = isEdit && !!initialData?.hasCashMovement
  const [registerInCash, setRegisterInCash] = useState(() => (isEdit ? hadCash : true))

  // El `kind` se resuelve del catálogo, nunca se escribe a mano.
  const { paymentMethods } = usePaymentMethods(isEdit)
  const resolvedKind = paymentMethods.find((pm) => pm.id === paymentMethodId)?.kind ?? null

  // D5: la exigencia de cuenta bancaria es CONDICIONAL a que la organización
  // tenga alguna activa — el mismo criterio que la RPC. Sin esto, 33 de 37
  // tenants no podrían registrar un gasto por transferencia.
  const { data: bankAccounts } = useBankAccounts()
  const hasActiveBankAccounts = (bankAccounts ?? []).some((b) => b.isActive)
  // En la edición sólo se exige cuando la forma de pago pasó a bancaria (el servidor pide destino cuando el kind cambia).
  const kindChanged = isEdit && resolvedKind !== (initialData?.paymentMethodKind ?? null)
  const bankAccountRequired =
    isBankPaymentKind(resolvedKind) && hasActiveBankAccounts && (isEdit ? kindChanged && !bankAccountId : true)

  // D16: mismo hook que el formulario de venta — las tres condiciones no se
  // reescriben, se reusan.
  // edicion-operaciones-con-dinero (D6): corregir lo ya registrado en caja no exige que la fecha sea hoy (variante «corrección»).
  const cashOptin = useCashOptin({ kind: resolvedKind, branchId, date, document: "gasto", requiresDate: !hadCash })
  const showCashBlock = cashOptin.isCashSelected
  // caja-optin-carga: con efectivo elegido, no se confirma mientras se averigua la
  // sesión (alta o edición: confirmar ahora mandaría la caja a ciegas, en silencio).
  const cashPending = showCashBlock && cashOptin.isLoading

  // ── edicion-operaciones-con-dinero (tanda C) ────────────────────────────────
  // Las intenciones de dinero viajan SÓLO cuando el usuario las cambió (tri-estado por ausencia). El plan exacto lo calcula el
  // servidor con la misma RPC en seco (`previewExpenseEdit`).
  const moneyIntent = buildEditMoneyIntent({
    cash: {
      finalKindIsCash: cashOptin.isCashSelected,
      hadCash,
      registerInCash,
      branchChanged: isEdit && (branchId ?? null) !== (initialData?.branchId ?? null),
      eligible: cashOptin.eligible,
      sessionId: cashOptin.session?.id ?? null,
    },
    bank: { touched: bankTouched, kindIsBank: isBankPaymentKind(resolvedKind), value: bankAccountId },
    due: { touched: false, isCredit: false, value: "" },
    reason,
  })

  /** El payload de la edición: el MISMO para la vista previa y para guardar. */
  function buildEditInput() {
    return {
      ...(initialData as Expense),
      category, description, amount, date,
      costCenterId, branchId, paymentMethodId,
      money: moneyIntent,
    }
  }

  const showEditError = useCallback((prefix: string, error: unknown) => {
    const raw = error instanceof Error ? error.message : typeof error === "string" ? error : "Error desconocido"
    const { message } = humanizeOperationError(raw, undefined, undefined, { intent: "edit" })
    toast.error(`${prefix}${message}`)
  }, [])

  // Se pide el plan cuando el gasto ya tiene dinero registrado o la forma de pago elegida puede escribirlo; el servidor decide
  // si hay algo que confirmar (sin cambios en ningún libro se guarda directo). Un gasto no tiene cuenta corriente.
  const hasMoneyFootprint = isEdit && (hadCash || !!initialData?.hasBankMovement)
  const needsPlan = isEdit && (hasMoneyFootprint || resolvedKind !== null)
  const submitButtonRef = useRef<HTMLButtonElement>(null)
  const planFlow = useEditPlanFlow({
    needsPlan,
    preview: () => previewExpenseEdit(buildEditInput()),
    execute: persist,
    onPreviewError: (error) => showEditError("Error al calcular el cambio: ", error),
  })

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    // Defensa en profundidad: el botón ya está deshabilitado, pero un submit por
    // otra vía (Enter) no puede registrar el gasto sin caja a ciegas.
    if (cashPending) return
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
    if (isEdit && needsPlan) {
      await planFlow.requestSave()
      return
    }
    await persist()
  }

  /** El guardado real: lo comparten el submit directo y la confirmación del plan. */
  async function persist() {
    try {
      if (isEdit && initialData) {
        const result = await updateExpenseMutation.mutateAsync(buildEditInput())
        // edicion-operaciones-con-dinero: con lo que el servidor dice que EJECUTÓ en los libros (su plan, no el que mostramos).
        const executed = summarizeExecutedPlan(result?.money ?? null, { party: "proveedor" })
        toast.success(`Gasto actualizado${executed ? `. ${executed}` : ""}`)
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
      if (isEdit) {
        showEditError("Error al actualizar gasto: ", error)
        return
      }
      const errorMsg =
        error instanceof Error ? error.message : typeof error === "string" ? error : "Error desconocido"
      toast.error(`Error al registrar gasto: ${errorMsg}`)
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

      {/* ── Cuenta bancaria de origen (D5, obligatoria en el alta) ──
          edicion-operaciones-con-dinero (D7): también al editar, con la cuenta de la huella; sólo se exige si la forma de pago
          pasó a bancaria, y sólo viaja si el usuario la cambia. */}
      <BankAccountDestinationSelect
        paymentMethodKind={resolvedKind}
        value={bankAccountId}
        onChange={handleBankAccountChange}
        required={bankAccountRequired}
        showEmptyNotice
        className="bg-background border-border text-foreground text-sm"
      />

      {/* ── Opt-in de caja (D1, pre-marcado — OQ-1) ────────────────
          Las tres condiciones las verifica el servidor; acá se muestran para
          que el usuario no descubra el bloqueo con un error. Cuando no
          aplican, el motivo se muestra: nunca se oculta en silencio. Mientras
          se averigua la sesión (caja-optin-carga) se avisa y el botón de
          registrar espera. */}
      {showCashBlock && (
        <CashOptinBlock
          cash={cashOptin}
          registerInCash={registerInCash}
          onRegisterInCashChange={setRegisterInCash}
          hadFootprint={hadCash}
        />
      )}

      {/* ── Sucursal (solo plan PRO) ───────────────────────────────── */}
      {/* compras-gastos-sucursal-por-defecto (D9): sin «Sin sucursal (general)»: se ve la
          sucursal PRINCIPAL ya elegida, rotulada «Nombre (principal)», con el rótulo
          «Sucursal» dentro del selector (desaparece junto con él en las cuentas sin el
          módulo de sucursales). El estado sigue en `null` hasta que se elige otra: viaja
          `null` y el SERVIDOR resuelve la principal — en el alta (desde gastos-forma-pago)
          y en la edición (un gasto histórico sin sucursal toma la principal al guardarse). */}
      <BranchSelect
        value={branchId}
        onChange={setBranchId}
        allowUnassigned={false}
        label="Sucursal"
        className="bg-background border-border text-foreground text-sm"
      />

      {/* ── Centro de costo (opcional, V2.5) ──────────────────────── */}
      <CostCenterSelect
        value={costCenterId}
        onChange={setCostCenterId}
        className="bg-background border-border text-foreground text-sm"
      />

      {/* ── Motivo del cambio (edicion-operaciones-con-dinero, D14/D17) ──
          Opcional; queda en el historial de cambios del gasto. */}
      {isEdit && (
        <div className="flex flex-col gap-2">
          <Label htmlFor="expense-edit-reason" className="text-foreground text-sm">
            Motivo del cambio <span className="text-muted-foreground font-normal">(opcional)</span>
          </Label>
          <Input
            id="expense-edit-reason"
            value={reason}
            maxLength={500}
            onChange={(e) => setReason(e.target.value)}
            placeholder="Ej: importe cargado de más"
            className="bg-background border-border text-foreground text-sm"
          />
        </div>
      )}

      <Button type="submit" ref={submitButtonRef} className="w-full" disabled={cashPending || planFlow.previewing}>
        {planFlow.previewing ? "Calculando el cambio..." : isEdit ? "Guardar cambios" : "Registrar gasto"}
      </Button>

      {/* edicion-operaciones-con-dinero (D13/D17): el plan que calculó el servidor, antes de guardar. */}
      <OperationEditPlanDialog
        open={planFlow.dialogOpen}
        onOpenChange={planFlow.setDialogOpen}
        preview={planFlow.preview}
        party="proveedor"
        documentLabel="este gasto"
        onConfirm={() => void planFlow.confirm()}
        executing={planFlow.executing}
        returnFocusRef={submitButtonRef}
      />
    </form>
  )
}
