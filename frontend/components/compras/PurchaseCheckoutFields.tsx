"use client"

/**
 * PurchaseCheckoutFields — los campos de cierre de una compra (remitos-compra
 * tanda B, D11, task 7.3): fecha, centro de costo, forma de pago, cuenta bancaria
 * destino, opt-in de caja y saldo del proveedor con cuenta corriente.
 *
 * Se extrajo de `components/forms/purchase-form.tsx` para que el formulario de
 * compra y el diálogo que convierte un remito de compra (`ConvertPurchaseDelivery
 * NoteDialog`) compartan el bloque sin copiarlo. Es CONTROLADO y no decide nada
 * por su cuenta: lo derivado (kind, caja, saldo) viene de `usePurchaseCheckout`,
 * que el contenedor también usa para el botón de confirmar.
 *
 * Dos props nuevas respecto de lo que el formulario ya hacía; sus defaults dejan al
 * formulario exactamente como estaba:
 *   - `showDueDate` (default false): el VENCIMIENTO de la deuda con el proveedor,
 *     sólo a crédito, pre-cargado por la cascada del plazo (`useDueDateCascade`,
 *     extraída de la venta) y editable. El formulario de compra directa NO lo gana
 *     en este change (candidato): la RPC lo acepta pero ese formulario no lo
 *     transporta;
 *   - `paymentRequired` (default false): la forma de pago es obligatoria (OQ-RC4,
 *     la compra nacida del remito es el momento de decir cómo se paga).
 *
 * Dos slots para que el formulario conserve su disposición:
 *   - `afterDate`: celdas de la grilla justo después de la fecha (las notas y la
 *     sucursal, que no forman parte de los campos de cierre);
 *   - `beforeCredit`: lo que va entre el bloque de caja y el de cuenta corriente (el
 *     selector de proveedor).
 *
 * `mode="edit"` (sólo el formulario): sin cuenta bancaria (la RPC de edición no la
 * tiene, D8) y con el bloque de crédito de la edición (la edición nunca postea
 * cargos: no proyecta saldo y avisa si se pasa a crédito).
 */

import type { ReactNode } from "react"
import { useId } from "react"
import { AlertCircle, CalendarIcon } from "lucide-react"
import { Checkbox } from "@/components/ui/checkbox"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { CostCenterSelect } from "@/components/cost-centers/CostCenterSelect"
import { BankAccountDestinationSelect, PaymentMethodSelect } from "@/components/payment-methods/PaymentMethodSelect"
import type { DueDateCascadeState } from "@/hooks/use-due-date-cascade"
import type { PurchaseCheckoutState } from "@/hooks/use-purchase-checkout"
import { argentinaToday } from "@/lib/date-range"
import { formatMoney } from "@/lib/format"

interface PurchaseCheckoutFieldsProps {
  checkout: PurchaseCheckoutState
  /** `create` (default): alta y conversión. `edit`: sólo el formulario de compra. */
  mode?: "create" | "edit"
  date: string
  onDateChange: (value: string) => void
  /** Fecha mínima (la de la recepción del remito: la compra no la puede preceder). */
  minDate?: string
  costCenterId: string | null
  onCostCenterChange: (value: string | null) => void
  paymentMethodId: string | null
  onPaymentMethodChange: (value: string | null) => void
  /** La forma de pago es obligatoria: oculta «Sin especificar». */
  paymentRequired?: boolean
  bankAccountId: string | null
  onBankAccountChange: (value: string | null) => void
  /** Muestra el vencimiento a crédito; exige `dueDate`. */
  showDueDate?: boolean
  dueDate?: DueDateCascadeState
  /** Edición: la forma de pago pasa de otra a crédito (el servidor lo rechaza, se avisa). */
  isTransitioningToCredit?: boolean
  /** Celdas de la grilla justo después de la fecha. */
  afterDate?: ReactNode
  /** Entre el bloque de caja y el de cuenta corriente. */
  beforeCredit?: ReactNode
  /** Disposición de la grilla; el formulario usa dos columnas fijas. */
  gridClassName?: string
  /** Deshabilita todos los campos (request en vuelo). */
  disabled?: boolean
}

const SELECT_CLASS = "bg-background border-border text-foreground text-sm"

export function PurchaseCheckoutFields({
  checkout,
  mode = "create",
  date,
  onDateChange,
  minDate,
  costCenterId,
  onCostCenterChange,
  paymentMethodId,
  onPaymentMethodChange,
  paymentRequired = false,
  bankAccountId,
  onBankAccountChange,
  showDueDate = false,
  dueDate,
  isTransitioningToCredit = false,
  afterDate,
  beforeCredit,
  gridClassName = "grid grid-cols-2 gap-3",
  disabled = false,
}: PurchaseCheckoutFieldsProps) {
  const isEdit = mode === "edit"
  const reactId = useId()
  const dateId = `purchase-date-${reactId}`
  const dueDateId = `purchase-due-date-${reactId}`

  return (
    <fieldset disabled={disabled} className="contents">
      <div className={gridClassName}>
        <div className="flex flex-col gap-2">
          <Label htmlFor={dateId} className="text-foreground flex items-center gap-1.5">
            <CalendarIcon className="h-3.5 w-3.5 text-muted-foreground" />
            Fecha
          </Label>
          <input
            id={dateId}
            type="date"
            value={date}
            min={minDate}
            max={argentinaToday()}
            onChange={(e) => onDateChange(e.target.value)}
            className="flex h-10 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
          />
        </div>

        {afterDate}

        {/* ── Centro de costo (opcional, V2.5) ──────────────────────── */}
        <CostCenterSelect value={costCenterId} onChange={onCostCenterChange} className={SELECT_CLASS} />

        {/* ── Forma de pago (metodos-pago-operaciones) ───────────────── */}
        <PaymentMethodSelect
          value={paymentMethodId}
          onChange={onPaymentMethodChange}
          context="purchase"
          required={paymentRequired}
          className={SELECT_CLASS}
        />

        {/* ── Cuenta bancaria destino del egreso (pos-banco-movimientos D9)
            Contiguo al selector de forma de pago; cero render si el kind no es
            bancario o la cuenta no tiene bancos cargados. Sin equivalente en
            edición (D8). */}
        {!isEdit && (
          <BankAccountDestinationSelect
            paymentMethodKind={checkout.kind}
            value={bankAccountId}
            onChange={onBankAccountChange}
            className={SELECT_CLASS}
          />
        )}
      </div>

      {/* ── Opt-in de caja (caja-compras-cobranzas D4, pre-marcado) ────────
          Las tres condiciones las verifica el servidor; acá se muestran para que el
          usuario no descubra el bloqueo con un error. Cuando no aplican, el motivo
          se muestra: nunca se oculta en silencio. Sólo en el alta (D8: la compra con
          caja posteada es inmutable). */}
      {checkout.showCashBlock && (
        <div className="flex flex-col gap-1.5 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs">
          {checkout.cash.eligible ? (
            <label className="flex items-center gap-2 cursor-pointer text-foreground">
              <Checkbox
                checked={checkout.registerInCash}
                onCheckedChange={(v) => checkout.setRegisterInCash(v === true)}
              />
              <span>Registrar en caja — sesión {checkout.cash.session?.id.slice(0, 8)}…</span>
            </label>
          ) : (
            <div role="note" className="flex items-center gap-2 text-muted-foreground">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              <span>{checkout.cash.reason}</span>
            </div>
          )}
        </div>
      )}

      {beforeCredit}

      {/* ── Bloque de cuenta corriente (D6/OQ-D) ───────────────────────────
          Mismo patrón visual que SaleForm: cliente→proveedor obligatorio + saldo
          actual/proyectado, sólo con 'credit'. Se muestra tanto en alta como en
          edición para explicar el efecto. La edición NUNCA postea ni revierte
          cargos (D7): a diferencia del alta, no tiene sentido mostrar «Después de
          esta compra» ahí (prometería un efecto que no ocurre). Si además se está
          TRANSICIONANDO a crédito desde otro kind (el servidor rechaza con
          credit_transition_not_allowed), se avisa aparte — sin bloquear el submit
          client-side. */}
      {checkout.isCredit && (
        <div className="flex flex-col gap-1.5 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs">
          {checkout.creditBlockedNoSupplier ? (
            <div className="flex items-center gap-2 text-warning">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              <span>Elegí un proveedor: una compra a cuenta corriente se le carga a alguien.</span>
            </div>
          ) : isEdit && isTransitioningToCredit ? (
            <div className="flex items-center gap-2 text-warning">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              <span>La edición no postea cargos: para pasar esta compra a crédito, borrala y volvé a cargarla.</span>
            </div>
          ) : isEdit ? (
            <div className="text-muted-foreground">Saldo actual: {formatMoney(checkout.supplierBalance)}</div>
          ) : (
            <>
              <div className="flex items-center justify-between gap-2 text-muted-foreground">
                <span>Saldo actual: {formatMoney(checkout.supplierBalance)}</span>
                <span className="font-medium text-foreground">
                  Después de esta compra: {formatMoney(checkout.projectedBalance)}
                </span>
              </div>
              {showDueDate && dueDate && (
                <>
                  {/* cobranzas-vencimientos (D11): vencimiento resuelto y EDITABLE.
                      Sólo viaja lo que el usuario toca; sin tocar, la cascada es del servidor. */}
                  <div className="flex items-center justify-between gap-2 pt-1 border-t border-border/60">
                    <Label htmlFor={dueDateId} className="text-xs text-muted-foreground shrink-0">
                      Vencimiento
                    </Label>
                    <Input
                      id={dueDateId}
                      type="date"
                      value={dueDate.dueDate}
                      min={date}
                      onChange={(e) => dueDate.setDueDate(e.target.value)}
                      className="h-7 w-auto bg-background border-border text-foreground text-xs"
                    />
                  </div>
                  <p className="text-[11px] text-muted-foreground">
                    {dueDate.touched && dueDate.dueDate
                      ? "Vencimiento elegido para esta compra."
                      : dueDate.effectiveTermsDays !== null
                        ? dueDate.termsSource === "entity"
                          ? `Resuelto por el plazo del proveedor (${dueDate.effectiveTermsDays} días).`
                          : `Resuelto por el plazo de la cuenta (${dueDate.effectiveTermsDays} días).`
                        : "Sin plazo configurado: el cargo nace sin vencimiento (podés elegir una fecha)."}
                  </p>
                </>
              )}
            </>
          )}
        </div>
      )}
    </fieldset>
  )
}
