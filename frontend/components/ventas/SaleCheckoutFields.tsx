"use client"

/**
 * SaleCheckoutFields — los campos de cierre de una venta (presupuestos-modulo
 * D12, task 6.9): sucursal, forma de pago, cuenta bancaria destino, aviso de
 * caja y saldo del cliente con cuenta corriente.
 *
 * Es CONTROLADO y no conoce el presupuesto: lo compone `ConvertQuoteDialog` y lo
 * reutiliza `ConvertDeliveryNoteDialog` (remitos-venta) sin refactor. Arma lo que ya existe
 * (`BranchSelect`, `PaymentMethodSelect`, `BankAccountDestinationSelect`) y no
 * decide nada por su cuenta: lo derivado (kind, sesión de caja, bloqueo) viene de
 * `useSaleCheckout`, que el contenedor también usa para el botón de confirmar.
 *
 * `branchReadOnly` (remitos-venta, D7): la sucursal NO se elige, se muestra por
 * nombre. La usa la conversión de un remito, que se imputa a la sucursal de donde
 * salió el stock: una venta en otra sucursal desalinearía la caja de su stock. Es
 * aditiva — sin ella (el presupuesto) el campo es el `BranchSelect` — y muestra el
 * nombre aunque el plan no tenga módulo de sucursales (el selector, en cambio, no
 * se renderiza en esos planes).
 *
 * ventas-sucursal-por-defecto (D9, tarea 6.7): la conversión REGISTRA UNA VENTA, y
 * toda superficie que registra una venta con un selector de sucursal usa
 * `allowUnassigned={false}`: sin «Sin sucursal» ni «Sucursal por defecto», muestra de
 * entrada la sucursal que el servidor va a usar. El contenedor ya resuelve esa
 * sucursal (la elegida, la del documento de origen o la principal) y la pasa como
 * `branchId`, así que lo mostrado es lo que se guarda. El rótulo «Sucursal» vive
 * dentro del selector: sin el módulo de sucursales no queda un rótulo huérfano.
 *
 * El texto del bloqueo vive en un elemento con `id` estable
 * (`SALE_CHECKOUT_REASON_ID`) para que el botón lo referencie con
 * `aria-describedby`.
 */

import Link from "next/link"
import { AlertCircle } from "lucide-react"
import { Label } from "@/components/ui/label"
import { BranchSelect } from "@/components/branches/BranchSelect"
import { BankAccountDestinationSelect, PaymentMethodSelect } from "@/components/payment-methods/PaymentMethodSelect"
import { useCustomerAccount } from "@/hooks/data/use-customer-account"
import type { SaleCheckoutState } from "@/hooks/use-sale-checkout"
import { formatMoney } from "@/lib/format"

export const SALE_CHECKOUT_REASON_ID = "sale-checkout-reason"

interface SaleCheckoutFieldsProps {
  branchId: string | null
  onBranchChange: (value: string | null) => void
  paymentMethodId: string | null
  onPaymentMethodChange: (value: string | null) => void
  bankAccountId: string | null
  onBankAccountChange: (value: string | null) => void
  /** Cliente de la venta: con cuenta corriente se muestra su saldo actual. */
  clientId: string | null
  checkout: SaleCheckoutState
  disabled?: boolean
  /** La sucursal viene dada por el documento y no se elige (conversión de un remito). */
  branchReadOnly?: boolean
  /** Nombre a mostrar con `branchReadOnly`; sin él se dice que es la del remito, sin inventar una. */
  branchName?: string | null
}

export function SaleCheckoutFields({
  branchId,
  onBranchChange,
  paymentMethodId,
  onPaymentMethodChange,
  bankAccountId,
  onBankAccountChange,
  clientId,
  checkout,
  disabled = false,
  branchReadOnly = false,
  branchName = null,
}: SaleCheckoutFieldsProps) {
  const isCredit = checkout.kind === "credit"
  const { data: customerAccount } = useCustomerAccount(isCredit ? clientId : null)

  return (
    <fieldset disabled={disabled} className="flex min-w-0 flex-col gap-4 border-0 p-0">
      {branchReadOnly ? (
        <div className="flex flex-col gap-2">
          <Label className="text-sm text-foreground">Sucursal</Label>
          <p className="min-w-0 break-words rounded-md border border-border bg-muted/40 px-3 py-2 text-sm font-medium text-foreground">
            {branchName ?? "La sucursal del remito"}
          </p>
        </div>
      ) : (
        <BranchSelect
          value={branchId}
          onChange={onBranchChange}
          allowUnassigned={false}
          label="Sucursal"
          className="bg-background border-border text-foreground"
        />
      )}

      <PaymentMethodSelect
        value={paymentMethodId}
        onChange={onPaymentMethodChange}
        label="Forma de pago"
        placeholder="Elegí la forma de pago"
        context="sale"
      />

      <BankAccountDestinationSelect
        paymentMethodKind={checkout.kind}
        value={bankAccountId}
        onChange={onBankAccountChange}
      />

      {isCredit && (
        <p className="text-sm text-muted-foreground">
          Saldo actual:{" "}
          <span className="font-medium tabular-nums text-foreground">
            {formatMoney(customerAccount?.balance ?? 0, "ARS")}
          </span>
        </p>
      )}

      {checkout.blockedReason && (
        <div
          role="status"
          className="flex items-start gap-3 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
        >
          <AlertCircle className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
          <div className="flex min-w-0 flex-col gap-1">
            <p id={SALE_CHECKOUT_REASON_ID}>{checkout.blockedReason}</p>
            {checkout.block === "cash_session" && (
              <Link href="/caja" className="w-fit text-xs text-primary underline underline-offset-2">
                Ir a Caja →
              </Link>
            )}
          </div>
        </div>
      )}
    </fieldset>
  )
}
