"use client"

/**
 * usePurchaseCheckout — lo que se DERIVA de los campos de cierre de una compra
 * (remitos-compra tanda B, D11, task 7.3): el `kind` de la forma de pago elegida,
 * las tres condiciones del opt-in de caja, la intención de registrar en caja y el
 * saldo del proveedor a crédito.
 *
 * Se extrajo de `components/forms/purchase-form.tsx`: el diálogo que convierte un
 * remito de compra en compra es el SEGUNDO consumidor del bloque exacto, así que se
 * extrae en vez de copiarse. Es el espejo de `useSaleCheckout` (venta). Los campos
 * (forma de pago, sucursal, fecha, proveedor) los guarda quien los usa; este hook
 * resuelve lo que cuelga de ellos y que tanto el panel de campos como el botón de
 * confirmar necesitan saber a la vez.
 *
 * La autoridad sigue siendo el servidor (`cash_optin_requires_*`, `P0422`,
 * `credit_requires_supplier`…): esto sólo evita que el usuario descubra el bloqueo
 * con un error. Reutiliza `useCashOptin` (tercer consumidor, con la fecha propia de
 * la compra: la caja exige hoy).
 */

import { useState } from "react"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useSupplierAccount } from "@/hooks/data/use-supplier-account"
import { useCashOptin, type CashOptinState } from "@/hooks/use-cash-optin"
import type { PaymentMethod, PaymentMethodKind } from "@/lib/types"

export interface UsePurchaseCheckoutParams {
  paymentMethodId: string | null
  /** Sucursal elegida o la del documento; null = la principal de la cuenta (la resuelve `useCashOptin`). */
  branchId: string | null
  /** Fecha de la compra, `YYYY-MM-DD`: la caja exige que sea hoy. */
  date: string
  /** Proveedor de la compra: lo exige la cuenta corriente. */
  supplierId: string | null
  /** Total de la compra, para proyectar el saldo del proveedor. */
  total: number
  /**
   * Edición del formulario: pide el catálogo COMPLETO de formas de pago (incluidas
   * las dadas de baja: la operación puede estar imputada a una desactivada, y esa
   * lista resuelve su `kind`) y NO ofrece la caja (D8: una compra con caja posteada
   * es inmutable).
   */
  isEdit?: boolean
}

export interface PurchaseCheckoutState {
  /** `kind` de la forma de pago elegida; `null` si no se eligió ninguna. */
  kind: PaymentMethodKind | null
  isCredit: boolean
  /** Las condiciones de caja resueltas para la sucursal efectiva. */
  cash: CashOptinState
  /** Se muestra el bloque «Registrar en caja»: forma de pago en efectivo y no es una edición. */
  showCashBlock: boolean
  /**
   * `caja-optin-carga`: se ofrece la caja (alta en efectivo) pero todavía se está
   * averiguando si hay sesión abierta. Mientras sea `true` NO se puede confirmar:
   * la sesión viajaría `null` y la compra en efectivo se registraría sin
   * movimiento de caja, en silencio. En la edición nunca es `true` (no hay caja).
   */
  cashPending: boolean
  /** Intención del usuario: arranca PRE-MARCADA (caja-compras-cobranzas D4). */
  registerInCash: boolean
  setRegisterInCash: (value: boolean) => void
  /** Sesión de caja a mandar: sólo con las tres condiciones cumplidas, tildado y fuera de la edición; si no, null. */
  cashSessionId: string | null
  /** Saldo actual del proveedor (0 mientras no resolvió su cuenta). */
  supplierBalance: number
  /** Saldo del proveedor después de esta compra. */
  projectedBalance: number
  /** A crédito y sin proveedor: la deuda no tendría a quién cargarse. */
  creditBlockedNoSupplier: boolean
  /** El catálogo de formas de pago que se usó para resolver el `kind`. */
  paymentMethods: PaymentMethod[]
}

export function usePurchaseCheckout({
  paymentMethodId,
  branchId,
  date,
  supplierId,
  total,
  isEdit = false,
}: UsePurchaseCheckoutParams): PurchaseCheckoutState {
  const { paymentMethods } = usePaymentMethods(isEdit)
  const kind = paymentMethods.find((pm) => pm.id === paymentMethodId)?.kind ?? null
  const isCredit = kind === "credit"

  // caja-compras-cobranzas (D2): mismo hook que venta y gasto — las tres condiciones
  // no se reescriben, se reusan.
  const cash = useCashOptin({ kind, branchId, date, document: "compra" })
  const [registerInCash, setRegisterInCash] = useState(true)
  const showCashBlock = !isEdit && cash.isCashSelected
  const cashPending = showCashBlock && cash.isLoading
  const cashSessionId = !isEdit && cash.eligible && registerInCash ? (cash.session?.id ?? null) : null

  const { data: supplierAccount } = useSupplierAccount(isCredit ? (supplierId || null) : null)
  const supplierBalance = supplierAccount?.balance ?? 0

  return {
    kind,
    isCredit,
    cash,
    showCashBlock,
    cashPending,
    registerInCash,
    setRegisterInCash,
    cashSessionId,
    supplierBalance,
    projectedBalance: supplierBalance + total,
    creditBlockedNoSupplier: isCredit && !supplierId,
    paymentMethods,
  }
}
