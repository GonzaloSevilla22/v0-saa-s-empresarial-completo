/**
 * Taxonomía del catálogo de formas de pago — etiquetas en castellano por
 * `kind` (gastos-forma-pago, D16 / task 8.2).
 *
 * Capa canónica, espejo de `lib/ledger/cash-movement-meta.ts` y de
 * `lib/bank-account-kind.ts`: las 7 etiquetas vivían dentro de
 * `PaymentMethodManager.tsx` como constante privada de módulo, así que
 * cualquier otra superficie que necesitara nombrar un `kind` tenía que
 * copiarlas. Acá suben, sin cambiar un literal.
 *
 * El literal de "no imputado" NO se redefine: se re-exporta el que ya existe
 * en `lib/payment-method-report.ts`, que es el que el reporte usa para la
 * fila `id = null`. Dos literales iguales en dos archivos divergen apenas
 * alguien toca uno.
 */

import type { PaymentMethodKind } from "@/lib/types"

export { UNASSIGNED_PAYMENT_METHOD_LABEL } from "@/lib/payment-method-report"

export const KIND_LABELS: Record<PaymentMethodKind, string> = {
  cash: "Efectivo",
  transfer: "Transferencia",
  card: "Tarjeta",
  check: "Cheque",
  wallet: "Billetera virtual",
  credit: "Cuenta corriente",
  other: "Otro",
}

/** Orden de presentación del catálogo — el mismo del manager. */
export const KIND_OPTIONS: PaymentMethodKind[] = [
  "cash", "transfer", "card", "check", "wallet", "credit", "other",
]
