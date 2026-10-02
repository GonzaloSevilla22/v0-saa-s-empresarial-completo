"use client"

/**
 * useSaleCheckout — lo que se DERIVA de los campos de cierre de una venta
 * (presupuestos-modulo D12, task 6.9).
 *
 * Los campos de cierre (sucursal, forma de pago, cuenta bancaria) los guarda
 * quien los usa; este hook resuelve lo que cuelga de ellos y que tanto el panel
 * de campos como el botón de confirmar necesitan saber a la vez:
 *   - el `kind` de la forma de pago elegida;
 *   - la sesión de caja abierta de la sucursal elegida, con la semántica del
 *     POS: con `kind = cash` se manda SIEMPRE esa sesión (sin checkbox de
 *     opt-in) y sin sesión no se puede confirmar;
 *   - el motivo por el que confirmar está bloqueado, o `null`.
 *
 * La autoridad sigue siendo el servidor (`cash_requires_session`, `P0422`…):
 * esto sólo evita que el usuario descubra el bloqueo con un error.
 *
 * No conoce el presupuesto: lo reutiliza cualquier cierre de venta
 * (`remitos-venta`). Reutiliza `useCashOptin` (las condiciones de caja, sin la
 * de fecha: una venta se cierra en el instante en que ocurre).
 */

import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useCashOptin, type CashOptinState } from "@/hooks/use-cash-optin"
import { argentinaToday } from "@/lib/date-range"
import type { PaymentMethodKind } from "@/lib/types"

/** Motivo bloqueante: por qué "confirmar" no se puede apretar todavía. */
export type SaleCheckoutBlock = "payment_method" | "cash_session" | "client" | null

export interface SaleCheckoutState {
  /** `kind` de la forma de pago elegida; `null` si no se eligió ninguna. */
  kind: PaymentMethodKind | null
  /** Las condiciones de caja resueltas para la sucursal efectiva. */
  cash: CashOptinState
  /** Sesión de caja a mandar: sólo con `kind = cash` y una sesión abierta. */
  cashSessionId: string | null
  block: SaleCheckoutBlock
  /** Texto del bloqueo, listo para mostrar; `null` si se puede confirmar. */
  blockedReason: string | null
}

export const SALE_CHECKOUT_PAYMENT_REQUIRED_REASON = "Elegí la forma de pago para registrar la venta."
export const SALE_CHECKOUT_NO_CASH_SESSION_REASON =
  "Abrí la caja de esta sucursal para cobrar en efectivo, o elegí otra forma de pago."
export const SALE_CHECKOUT_CREDIT_NEEDS_CLIENT_REASON =
  "Elegí un cliente: una venta a cuenta corriente se le carga a alguien."

export interface UseSaleCheckoutParams {
  paymentMethodId: string | null
  /** Sucursal efectiva ya resuelta por quien llama (la elegida o la del documento). */
  branchId: string | null
  /** Cliente de la venta: lo exige la cuenta corriente. */
  clientId: string | null
}

export function useSaleCheckout({ paymentMethodId, branchId, clientId }: UseSaleCheckoutParams): SaleCheckoutState {
  const { paymentMethods } = usePaymentMethods()
  const kind = paymentMethods.find((pm) => pm.id === paymentMethodId)?.kind ?? null

  const cash = useCashOptin({
    kind,
    branchId,
    date: argentinaToday(),
    document: "venta",
    // Sin fecha propia: la condición de fecha de caja no aplica a un cierre inmediato.
    requiresDate: false,
  })

  const block: SaleCheckoutBlock =
    !paymentMethodId || kind === null
      ? "payment_method"
      : cash.isCashSelected && !cash.session
        ? "cash_session"
        : kind === "credit" && !clientId
          ? "client"
          : null

  const blockedReason =
    block === "payment_method"
      ? SALE_CHECKOUT_PAYMENT_REQUIRED_REASON
      : block === "cash_session"
        ? SALE_CHECKOUT_NO_CASH_SESSION_REASON
        : block === "client"
          ? SALE_CHECKOUT_CREDIT_NEEDS_CLIENT_REASON
          : null

  return {
    kind,
    cash,
    cashSessionId: cash.isCashSelected ? cash.session?.id ?? null : null,
    block,
    blockedReason,
  }
}
