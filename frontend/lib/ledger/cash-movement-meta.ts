/**
 * Taxonomía de tipos del libro de Caja — label/ícono/tono/familia por tipo
 * (task 7.4). Fuente única para LedgerMovementsPanel en modo `cash`.
 *
 * Tonos semánticos (tokens-contraste-aa, 2026-08-17): nunca colores
 * literales (`text-emerald-400` etc, como hace el molde de Stock) — siempre
 * `success`/`destructive`/`warning`/`primary`/`muted`, resueltos por
 * `LedgerMovementsPanel` a `bg-{tone}/15 text-{tone} border-{tone}/25`.
 */
import {
  ArrowUpCircle, ArrowDownCircle, ShoppingBag, Wallet,
  RotateCcw, Scale, Undo2,
} from "lucide-react"
import type { LedgerFamily, LedgerMovementMeta } from "./types"
import type { CashMovementType } from "@/lib/types"

export const CASH_MOVEMENT_META: Record<CashMovementType, LedgerMovementMeta> = {
  sale:             { label: "Venta",              icon: ArrowUpCircle,  tone: "success",     family: "income" },
  advance:          { label: "Adelanto / depósito", icon: ArrowUpCircle, tone: "success",     family: "income" },
  // caja-compras-cobranzas (OQ-3): relabel — este tipo pasa a significar
  // "compra al contado", no "pago a proveedor" (ese nombre ahora es de
  // payment_made). 0 filas en prod al momento del cambio, así que el relabel
  // no reescribe historia. El ícono (ShoppingBag) ya encajaba mejor con el
  // significado nuevo que con el viejo.
  purchase_payment: { label: "Compra en efectivo",  icon: ShoppingBag,   tone: "destructive", family: "expense" },
  expense:          { label: "Gasto",               icon: ArrowDownCircle, tone: "destructive", family: "expense" },
  withdrawal:       { label: "Retiro",              icon: Wallet,        tone: "destructive", family: "expense" },
  sale_reversal:    { label: "Reversa de venta",    icon: RotateCcw,     tone: "warning",     family: "reversal" },
  // gastos-forma-pago (D9): FAMILIA `reversal`, junto a sale_reversal — NO
  // `income`. El espejo de sale_reversal es de familia; el de signo es el
  // opuesto y vive en backend/schemas/cash.py (_INCOME_TYPES).
  expense_reversal: { label: "Reversa de gasto",    icon: RotateCcw,     tone: "warning",     family: "reversal" },
  // caja-compras-cobranzas (D1): tres tipos nuevos. purchase_payment_reversal
  // es ingreso por signo (revertir un egreso repone plata) y Reversas por
  // familia — mismo patrón que expense_reversal/sale_reversal. payment_received
  // y payment_made son los productores reales del cobro/pago de cta cte.
  purchase_payment_reversal: { label: "Reversa de compra", icon: RotateCcw,      tone: "warning",     family: "reversal" },
  payment_received:          { label: "Cobro de cliente",  icon: ArrowUpCircle,  tone: "success",     family: "income" },
  payment_made:               { label: "Pago a proveedor",  icon: ArrowDownCircle, tone: "destructive", family: "expense" },
  // cobranzas-reverso (D10): anulación de cobro/pago — familia "Reversas"
  // (junto a las otras tres), pero SIGNO OPUESTO entre sí: anular un cobro
  // SACA plata del cajón (egreso/destructive), anular un pago la REPONE
  // (ingreso/success) — al revés del tono de su hecho original. Ícono propio
  // (Undo2) para distinguirlas visualmente de sale_reversal/expense_reversal/
  // purchase_payment_reversal en el filtro "Reversas".
  payment_received_reversal: { label: "Anulación de cobro", icon: Undo2, tone: "destructive", family: "reversal" },
  payment_made_reversal:     { label: "Anulación de pago",  icon: Undo2, tone: "success",     family: "reversal" },
  adjustment:       { label: "Ajuste",              icon: Scale,         tone: "warning",     family: "adjustment" },
}

export const CASH_MOVEMENT_FAMILIES: LedgerFamily[] = [
  { key: "all",        label: "Todos",     types: [] },
  { key: "income",     label: "Ingresos",  types: ["sale", "advance", "payment_received"] },
  { key: "expense",    label: "Egresos",   types: ["purchase_payment", "expense", "withdrawal", "payment_made"] },
  { key: "reversal",   label: "Reversas",  types: ["sale_reversal", "expense_reversal", "purchase_payment_reversal", "payment_received_reversal", "payment_made_reversal"] },
  { key: "adjustment", label: "Ajustes",   types: ["adjustment"] },
]
