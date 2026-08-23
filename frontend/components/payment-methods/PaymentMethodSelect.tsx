"use client"

import Link from "next/link"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Label } from "@/components/ui/label"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"
import { isBankPaymentKind, type PaymentMethodKind } from "@/lib/types"
import { getAccountKindIcon } from "@/lib/bank-account-kind"

interface PaymentMethodSelectProps {
  value: string | null
  onChange: (value: string | null) => void
  placeholder?: string
  className?: string
  /** Label shown above the select. Pass false to hide (default: shown). */
  showLabel?: boolean
  /** Text of the label when shown (default: the new-entry wording). */
  label?: string
  /**
   * metodos-pago-operaciones: include deactivated methods in the options.
   *
   * false (default) for NEW entries — a method that was given up shouldn't be
   * imputable. true when filtering existing records or editing one that was
   * imputed to a since-deactivated method (its history still has to be
   * reachable, D "La baja es desactivación y preserva la imputación").
   */
  includeInactive?: boolean
  /** D8: which support text to show when kind is 'credit' (cliente vs proveedor). Default "sale". */
  context?: "sale" | "purchase"
  /**
   * D8: show the "esto no genera X" support text below the select. Default
   * true for forms (new entry / edit). Set false for filter usages — the
   * disclaimer is about what CHOOSING a method does, not about filtering.
   */
  showSupportText?: boolean
}

/**
 * Dropdown to pick a payment method — used both to assign one to a new sale
 * or purchase and to filter the sale/purchase lists. Espejo de
 * CostCenterSelect (metodos-pago-operaciones).
 *
 * Renders a plain label+select — no plan-gating since the payment method
 * catalog is available on all plans (D10).
 */
export function PaymentMethodSelect({
  value,
  onChange,
  placeholder = "Sin especificar",
  className,
  showLabel = true,
  label,
  includeInactive = false,
  context = "sale",
  showSupportText = true,
}: PaymentMethodSelectProps) {
  const { paymentMethods, isLoading } = usePaymentMethods(includeInactive)

  return (
    <div className="flex flex-col gap-2">
      {showLabel && (
        <Label className="text-foreground text-sm">
          {label ?? (
            <>
              Forma de pago <span className="text-muted-foreground font-normal">(opcional)</span>
            </>
          )}
        </Label>
      )}
      <Select
        value={value ?? "__none__"}
        onValueChange={(v) => onChange(v === "__none__" ? null : v)}
        disabled={isLoading}
      >
        <SelectTrigger className={className ?? "bg-background border-border text-foreground"}>
          <SelectValue placeholder={placeholder} />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="__none__">{placeholder}</SelectItem>
          {paymentMethods.map((pm) => (
            <SelectItem key={pm.id} value={pm.id}>
              {pm.name}
              {!pm.isActive && " (inactiva)"}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {showSupportText && (
        <PaymentMethodSupportText kind={paymentMethods.find((pm) => pm.id === value)?.kind ?? null} context={context} />
      )}
    </div>
  )
}

interface PaymentMethodSupportTextProps {
  kind: PaymentMethodKind | null
  context: "sale" | "purchase"
}

/**
 * D8 / pos-catalogo-pagos D5, actualizado por pagos-cableados-restantes
 * (OQ-C/OQ-D/OQ-E) — Etiqueta honesta: el selector dice lo que hace y lo que
 * no, y el "no" cambió con este change. Si no se dice, el usuario asume que
 * la etiqueta sola alcanza (mismo patrón de superficie huérfana que dejó
 * `credit` cableado sin UI y la cuenta corriente en cero). Texto de apoyo
 * condicionado al kind elegido Y al contexto (venta/compra — los efectos
 * NO son simétricos: el lado proveedor sigue recortado, ver OQ-E).
 *
 * Venta — 'credit': ahora SÍ postea el cargo (POS y formulario, vía el
 * helper compartido _pay_register_party_charge) — exige cliente.
 * Venta — 'cash': el POS sigue moviendo caja automáticamente; el
 * FORMULARIO puede ahora optar-in con el checkbox "Registrar en caja",
 * condicionado a sesión abierta hoy en la sucursal.
 * Compra — 'credit'/'cash': SIN CAMBIOS — el lado proveedor sigue sin cargo
 * automático (0 proveedores, sin selector en el form — compras-proveedor-
 * cuenta-corriente es un change aparte).
 */
export function PaymentMethodSupportText({ kind, context }: PaymentMethodSupportTextProps) {
  // pos-banco-movimientos: la etiqueta bancaria dice lo que hace — el texto
  // se resuelve en BankAccountDestinationSelect (nombra la cuenta elegida o
  // el default configurado), acá sólo se cubre la ausencia de contexto de
  // cuenta bancaria (sin bank_accounts cargadas — D9, cero UI).
  if (kind === "credit") {
    return (
      <p className="text-xs text-muted-foreground">
        {context === "sale"
          ? "Esta forma de pago carga la venta a la cuenta corriente del cliente al confirmarla — requiere elegir un cliente."
          : "Esta etiqueta no genera un cargo en la cuenta corriente del proveedor. Para eso, registrá el pago desde la cuenta corriente del proveedor."}
      </p>
    )
  }
  if (kind === "cash") {
    return (
      <p className="text-xs text-muted-foreground">
        {context === "sale" ? (
          <>
            El{" "}
            <Link href="/ventas/pos" className="underline underline-offset-2 hover:opacity-80">
              POS
            </Link>{" "}
            registra el movimiento de caja automáticamente. Desde este formulario podés optar por
            registrarlo también, tildando "Registrar en caja" — sólo si hay una sesión abierta hoy
            en la sucursal.
          </>
        ) : (
          "Esta etiqueta registra cómo se pagó. No genera ningún movimiento de caja."
        )}
      </p>
    )
  }
  return null
}

// ── pos-banco-movimientos (D9, task 9.5): selector de cuenta contiguo ──────

interface BankAccountDestinationSelectProps {
  /** El kind de la forma de pago actualmente elegida (o null si ninguna). */
  paymentMethodKind: PaymentMethodKind | null
  value: string | null
  onChange: (value: string | null) => void
  className?: string
}

/**
 * Selector de cuenta bancaria destino, contiguo al de forma de pago —
 * override de la operación sobre el default configurado en el método (D2).
 *
 * Visible SÓLO cuando el kind elegido es bancario (transfer/card/check/
 * wallet) Y la organización tiene al menos una cuenta bancaria activa
 * cargada — D9: "cero render" para el resto (34 de 35 cuentas hoy). Nunca
 * exige elegir: dejarlo en blanco usa el default del método (o no registra
 * nada si tampoco hay default).
 */
export function BankAccountDestinationSelect({
  paymentMethodKind,
  value,
  onChange,
  className,
}: BankAccountDestinationSelectProps) {
  const { data: bankAccounts, isLoading } = useBankAccounts()
  const activeAccounts = (bankAccounts ?? []).filter((b) => b.isActive)

  if (!isBankPaymentKind(paymentMethodKind)) return null
  if (activeAccounts.length === 0) return null

  return (
    <div className="flex flex-col gap-2">
      <Label className="text-foreground text-sm">
        Cuenta bancaria <span className="text-muted-foreground font-normal">(opcional)</span>
      </Label>
      <Select
        value={value ?? "__default__"}
        onValueChange={(v) => onChange(v === "__default__" ? null : v)}
        disabled={isLoading}
      >
        <SelectTrigger className={className ?? "bg-background border-border text-foreground"}>
          <SelectValue placeholder="Usar el destino configurado" />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="__default__">Usar el destino configurado</SelectItem>
          {activeAccounts.map((b) => {
            const AccountIcon = getAccountKindIcon(b.accountKind)
            return (
              <SelectItem key={b.id} value={b.id}>
                <span className="flex items-center gap-1.5">
                  <AccountIcon className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                  {b.name}
                </span>
              </SelectItem>
            )
          })}
        </SelectContent>
      </Select>
      <p className="text-xs text-muted-foreground">
        Registra el movimiento en la cuenta bancaria elegida. Sin elegir ninguna, se usa el destino
        configurado en la forma de pago — si tampoco tiene uno, no se registra ningún movimiento.
      </p>
    </div>
  )
}
