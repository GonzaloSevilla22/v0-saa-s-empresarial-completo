"use client"

import { useId } from "react"
import Link from "next/link"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Label } from "@/components/ui/label"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useBankAccounts } from "@/hooks/data/use-bank-accounts"
import { isBankPaymentKind, type PaymentMethodKind } from "@/lib/types"
import { getAccountKindIcon } from "@/lib/bank-account-kind"

export type PaymentMethodContext = "sale" | "purchase" | "expense"

/**
 * Opciones ofrecidas por contexto — D3. Es la regla que usa el render, no una
 * copia: el `.map()` del componente consume exactamente esta función.
 */
export function paymentMethodOptionsFor<T extends { kind: PaymentMethodKind }>(
  methods: T[],
  context: PaymentMethodContext,
): T[] {
  return context === "expense" ? methods.filter((pm) => pm.kind !== "credit") : methods
}

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
  /**
   * D8: which support text to show when kind is 'credit' (cliente vs
   * proveedor). Default "sale".
   *
   * gastos-forma-pago (D3, task 10.2): suma "expense" — EXTENSIÓN ADITIVA,
   * no un selector nuevo. En ese contexto las formas de pago de
   * `kind = 'credit'` NO se ofrecen: `expenses` no tiene contraparte
   * (ni `supplier_id` ni `client_id`), así que no hay cuenta corriente que
   * cargar. El servidor lo respalda con `P0400` para que la API no sea un
   * bypass de la UI.
   */
  context?: PaymentMethodContext
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
  const options = paymentMethodOptionsFor(paymentMethods, context)
  const selectedKind = paymentMethods.find((pm) => pm.id === value)?.kind ?? null

  // a11y (task 10.7): sin `htmlFor`/`id` el campo no era alcanzable por su
  // label, y el texto de apoyo —el que dice qué hace y qué NO hace la forma
  // de pago elegida— no lo leía ningún lector de pantalla. Mismo gap que el
  // precedente de proveedores encontró en `supplier-form.tsx`.
  const reactId = useId()
  const selectId = `payment-method-${reactId}`
  const supportId = `payment-method-support-${reactId}`
  const hasSupportText = showSupportText && (selectedKind === "credit" || selectedKind === "cash")

  return (
    <div className="flex flex-col gap-2">
      {showLabel && (
        <Label htmlFor={selectId} className="text-foreground text-sm">
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
        <SelectTrigger
          id={selectId}
          aria-describedby={hasSupportText ? supportId : undefined}
          className={className ?? "bg-background border-border text-foreground"}
        >
          <SelectValue placeholder={placeholder} />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="__none__">{placeholder}</SelectItem>
          {options.map((pm) => (
            <SelectItem key={pm.id} value={pm.id}>
              {pm.name}
              {!pm.isActive && " (inactiva)"}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
      {showSupportText && (
        <PaymentMethodSupportText id={supportId} kind={selectedKind} context={context} />
      )}
    </div>
  )
}

interface PaymentMethodSupportTextProps {
  kind: PaymentMethodKind | null
  context: PaymentMethodContext
  /** a11y: id al que apunta el `aria-describedby` del selector. */
  id?: string
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
export function PaymentMethodSupportText({ kind, context, id }: PaymentMethodSupportTextProps) {
  // pos-banco-movimientos: la etiqueta bancaria dice lo que hace — el texto
  // se resuelve en BankAccountDestinationSelect (nombra la cuenta elegida o
  // el default configurado), acá sólo se cubre la ausencia de contexto de
  // cuenta bancaria (sin bank_accounts cargadas — D9, cero UI).
  if (kind === "credit") {
    // gastos-forma-pago (D3): en gastos ni siquiera se ofrece, pero un gasto
    // histórico puede tener imputada una forma de pago que después pasó a
    // `credit` — el texto tiene que decir cuál es el camino correcto.
    if (context === "expense") {
      return (
        <p id={id} className="text-xs text-muted-foreground">
          Un gasto no tiene cuenta corriente. Para un gasto que vas a pagar después,
          cargalo como compra a proveedor: la cuenta corriente vive ahí.
        </p>
      )
    }
    return (
      <p id={id} className="text-xs text-muted-foreground">
        {context === "sale"
          ? "Esta forma de pago carga la venta a la cuenta corriente del cliente al confirmarla — requiere elegir un cliente."
          : "Esta etiqueta no genera un cargo en la cuenta corriente del proveedor. Para eso, registrá el pago desde la cuenta corriente del proveedor."}
      </p>
    )
  }
  if (kind === "cash") {
    // gastos-forma-pago (D1): el opt-in del gasto arranca PRE-MARCADO (OQ-1),
    // al revés que el de venta — la asimetría es deliberada y se dice acá.
    if (context === "expense") {
      return (
        <p id={id} className="text-xs text-muted-foreground">
          El egreso se registra en la caja abierta, salvo que destildes "Registrar en
          caja" (por ejemplo, si lo pagaste de otro bolsillo). Sólo si hay una sesión
          abierta hoy en la sucursal.
        </p>
      )
    }
    return (
      <p id={id} className="text-xs text-muted-foreground">
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
  /**
   * gastos-forma-pago (D5 / OQ-2 firmada): en el formulario de GASTO elegir
   * la cuenta es OBLIGATORIO — desaparece la opción "usar el destino
   * configurado". Motivo medido: hay 0 de 37 catálogos con `bank_account_id`
   * configurado, así que el default no resuelve para NINGÚN tenant y el
   * movimiento bancario no se escribiría — un no-op silencioso, que es
   * exactamente lo que este change viene a cerrar. La RPC lo respalda con
   * `P0412` cuando la organización tiene cuentas activas.
   */
  required?: boolean
  /**
   * Cuando la organización no tiene NINGUNA cuenta bancaria activa (33 de 37
   * hoy), el componente devuelve `null` — cero render. Con esto en `true`
   * muestra en su lugar el motivo: el gasto se guarda igual, pero no va a
   * llegar a la conciliación, y eso no puede quedar en silencio.
   */
  showEmptyNotice?: boolean
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
  required = false,
  showEmptyNotice = false,
}: BankAccountDestinationSelectProps) {
  const { data: bankAccounts, isLoading } = useBankAccounts()
  const activeAccounts = (bankAccounts ?? []).filter((b) => b.isActive)

  if (!isBankPaymentKind(paymentMethodKind)) return null
  if (activeAccounts.length === 0) {
    if (!showEmptyNotice) return null
    return (
      <p className="text-xs text-muted-foreground" data-testid="bank-accounts-empty-notice">
        No tenés cuentas bancarias cargadas: este gasto se va a guardar con su forma de
        pago, pero no va a aparecer en la conciliación bancaria.
      </p>
    )
  }

  const selectId = "bank-account-destination"
  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor={selectId} className="text-foreground text-sm">
        Cuenta bancaria{" "}
        <span className="text-muted-foreground font-normal">
          {required ? "(obligatorio)" : "(opcional)"}
        </span>
      </Label>
      <Select
        value={value ?? (required ? "" : "__default__")}
        onValueChange={(v) => onChange(v === "__default__" ? null : v)}
        disabled={isLoading}
      >
        <SelectTrigger id={selectId} className={className ?? "bg-background border-border text-foreground"}>
          <SelectValue placeholder={required ? "Elegí la cuenta de la que sale el dinero" : "Usar el destino configurado"} />
        </SelectTrigger>
        <SelectContent>
          {!required && <SelectItem value="__default__">Usar el destino configurado</SelectItem>}
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
        {required
          ? "El egreso se registra en la cuenta elegida y queda pendiente de conciliar."
          : "Registra el movimiento en la cuenta bancaria elegida. Sin elegir ninguna, se usa el destino configurado en la forma de pago — si tampoco tiene uno, no se registra ningún movimiento."}
      </p>
    </div>
  )
}
