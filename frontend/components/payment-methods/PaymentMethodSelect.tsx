"use client"

import Link from "next/link"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Label } from "@/components/ui/label"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import type { PaymentMethodKind } from "@/lib/types"

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
 * D8 / pos-catalogo-pagos D5 — Etiqueta honesta: el selector dice lo que
 * hace y lo que no. Elegir una forma de pago de kind 'credit' en el form NO
 * genera cargo en la cuenta corriente, y 'cash' en el form NO mueve caja —
 * la caja la mueve el CAMINO (el POS), no la etiqueta (regla de negocio
 * explícita en el spec `cash-session`). Si no se dice, el usuario asume que
 * la etiqueta sola alcanza (mismo patrón de superficie huérfana que dejó
 * `credit` cableado sin UI y la cuenta corriente en cero). Texto de apoyo
 * condicionado al kind elegido, para los tres consumidores (form de venta,
 * form de compra, filtros).
 */
export function PaymentMethodSupportText({ kind, context }: PaymentMethodSupportTextProps) {
  if (kind === "credit") {
    return (
      <p className="text-xs text-muted-foreground">
        {context === "sale"
          ? "Esta etiqueta no genera un cargo en la cuenta corriente del cliente. Para eso, registrá el cobro desde la cuenta corriente del cliente."
          : "Esta etiqueta no genera un cargo en la cuenta corriente del proveedor. Para eso, registrá el pago desde la cuenta corriente del proveedor."}
      </p>
    )
  }
  if (kind === "cash") {
    return (
      <p className="text-xs text-muted-foreground">
        Esta etiqueta registra cómo se cobró. El movimiento de caja lo genera la venta desde el{" "}
        <Link href="/ventas/pos" className="underline underline-offset-2 hover:opacity-80">
          POS
        </Link>
        , que exige una sesión abierta.
      </p>
    )
  }
  return null
}
