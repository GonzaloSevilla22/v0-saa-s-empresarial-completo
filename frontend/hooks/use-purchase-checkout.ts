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
 *
 * edicion-operaciones-con-dinero (tanda C): la EDICIÓN ya compensa y registra en caja, cuenta corriente y banco, así que el
 * bloque de caja se ofrece también al editar. Parte de lo que HAY (`hadCash`: «Registrado en caja» marcado si la operación
 * tiene movimiento de caja vigente, desmarcado si no), y corregir lo ya registrado no exige que la fecha sea hoy. A
 * diferencia del alta, `cashSessionId` es siempre null al editar: qué clave de caja viaja la decide `buildEditMoneyIntent`
 * (tri-estado por ausencia), no este hook.
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
   * lista resuelve su `kind`).
   */
  isEdit?: boolean
  /** Edición: la compra YA tiene movimiento de caja vigente (huella neta). */
  hadCash?: boolean
  /**
   * Edición: el cargo que la compra ya tiene en la cuenta corriente de ESTE proveedor. El saldo de la cuenta lo incluye, así
   * que se descuenta para no contarlo dos veces en el saldo proyectado.
   */
  alreadyCharged?: number
}

export interface PurchaseCheckoutState {
  /** `kind` de la forma de pago elegida; `null` si no se eligió ninguna. */
  kind: PaymentMethodKind | null
  isCredit: boolean
  /** Las condiciones de caja resueltas para la sucursal efectiva. */
  cash: CashOptinState
  /** Se muestra el bloque de caja: la forma de pago es efectivo (en el alta y en la edición). */
  showCashBlock: boolean
  /** Edición: la compra tenía movimiento de caja (el bloque dice «Registrado en caja»). */
  hadCash: boolean
  /**
   * `caja-optin-carga`: se ofrece la caja (efectivo) pero todavía se está averiguando si hay sesión
   * abierta. Mientras sea `true` NO se puede confirmar: la sesión viajaría `null` y la compra en
   * efectivo se registraría sin movimiento de caja, en silencio.
   */
  cashPending: boolean
  /** Intención del usuario: PRE-MARCADA en el alta (caja-compras-cobranzas D4); al editar, parte de `hadCash`. */
  registerInCash: boolean
  setRegisterInCash: (value: boolean) => void
  /** Alta: sesión de caja a mandar, sólo con las tres condiciones cumplidas y tildado; si no, null. Al editar siempre null. */
  cashSessionId: string | null
  /** Saldo actual del proveedor (0 mientras no resolvió su cuenta). */
  supplierBalance: number
  /** Saldo del proveedor después de esta compra (al editar, sin contar dos veces el cargo vigente). */
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
  hadCash = false,
  alreadyCharged = 0,
}: UsePurchaseCheckoutParams): PurchaseCheckoutState {
  const { paymentMethods } = usePaymentMethods(isEdit)
  const kind = paymentMethods.find((pm) => pm.id === paymentMethodId)?.kind ?? null
  const isCredit = kind === "credit"
  const hadCashFootprint = isEdit && hadCash

  // caja-compras-cobranzas (D2): mismo hook que venta y gasto — las tres condiciones
  // no se reescriben, se reusan. Corregir lo ya registrado en caja no exige la fecha de hoy.
  const cash = useCashOptin({ kind, branchId, date, document: "compra", requiresDate: !hadCashFootprint })
  const [registerInCash, setRegisterInCash] = useState(() => (isEdit ? hadCash : true))
  const showCashBlock = cash.isCashSelected
  const cashPending = showCashBlock && cash.isLoading
  const cashSessionId = !isEdit && cash.eligible && registerInCash ? (cash.session?.id ?? null) : null

  const { data: supplierAccount } = useSupplierAccount(isCredit ? (supplierId || null) : null)
  const supplierBalance = supplierAccount?.balance ?? 0

  return {
    kind,
    isCredit,
    cash,
    showCashBlock,
    hadCash: hadCashFootprint,
    cashPending,
    registerInCash,
    setRegisterInCash,
    cashSessionId,
    supplierBalance,
    projectedBalance: supplierBalance + total - alreadyCharged,
    creditBlockedNoSupplier: isCredit && !supplierId,
    paymentMethods,
  }
}
