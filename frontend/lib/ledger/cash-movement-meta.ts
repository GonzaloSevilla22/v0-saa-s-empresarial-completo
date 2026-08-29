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
  RotateCcw, Scale,
} from "lucide-react"
import type { LedgerFamily, LedgerMovementMeta } from "./types"
import type { CashMovementType } from "@/lib/types"

export const CASH_MOVEMENT_META: Record<CashMovementType, LedgerMovementMeta> = {
  sale:             { label: "Venta",              icon: ArrowUpCircle,  tone: "success",     family: "income" },
  advance:          { label: "Adelanto / depósito", icon: ArrowUpCircle, tone: "success",     family: "income" },
  purchase_payment: { label: "Pago a proveedor",    icon: ShoppingBag,   tone: "destructive", family: "expense" },
  expense:          { label: "Gasto",               icon: ArrowDownCircle, tone: "destructive", family: "expense" },
  withdrawal:       { label: "Retiro",              icon: Wallet,        tone: "destructive", family: "expense" },
  sale_reversal:    { label: "Reversa de venta",    icon: RotateCcw,     tone: "warning",     family: "reversal" },
  // gastos-forma-pago (D9): FAMILIA `reversal`, junto a sale_reversal — NO
  // `income`. El espejo de sale_reversal es de familia; el de signo es el
  // opuesto y vive en backend/schemas/cash.py (_INCOME_TYPES).
  expense_reversal: { label: "Reversa de gasto",    icon: RotateCcw,     tone: "warning",     family: "reversal" },
  adjustment:       { label: "Ajuste",              icon: Scale,         tone: "warning",     family: "adjustment" },
}

export const CASH_MOVEMENT_FAMILIES: LedgerFamily[] = [
  { key: "all",        label: "Todos",     types: [] },
  { key: "income",     label: "Ingresos",  types: ["sale", "advance"] },
  { key: "expense",    label: "Egresos",   types: ["purchase_payment", "expense", "withdrawal"] },
  { key: "reversal",   label: "Reversas",  types: ["sale_reversal", "expense_reversal"] },
  { key: "adjustment", label: "Ajustes",   types: ["adjustment"] },
]
