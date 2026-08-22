/**
 * Taxonomía de tipos del libro de Banco — label/ícono/tono/familia por tipo
 * (task 7.4). Fuente única para LedgerMovementsPanel en modo `bank`.
 */
import {
  ArrowRightLeft, CreditCard, Receipt, Landmark, TrendingUp, Scale,
} from "lucide-react"
import type { LedgerFamily, LedgerMovementMeta } from "./types"
import type { BankMovementType } from "@/lib/types"

export const BANK_MOVEMENT_META: Record<BankMovementType, LedgerMovementMeta> = {
  transfer_in:      { label: "Transferencia ent.", icon: ArrowRightLeft, tone: "success",     family: "transfer" },
  transfer_out:      { label: "Transferencia sal.", icon: ArrowRightLeft, tone: "destructive", family: "transfer" },
  card_settlement:  { label: "Liquidación tarjeta", icon: CreditCard,    tone: "success",     family: "settlement" },
  fee:              { label: "Comisión",           icon: Receipt,        tone: "destructive", family: "charge" },
  tax_debit:        { label: "Débito fiscal",      icon: Landmark,       tone: "destructive", family: "charge" },
  interest:         { label: "Interés",            icon: TrendingUp,     tone: "warning",     family: "charge" },
  manual_adjustment: { label: "Ajuste",             icon: Scale,          tone: "warning",     family: "adjustment" },
}

export const BANK_MOVEMENT_FAMILIES: LedgerFamily[] = [
  { key: "all",        label: "Todos",         types: [] },
  { key: "transfer",   label: "Transferencias", types: ["transfer_in", "transfer_out"] },
  { key: "settlement", label: "Liquidaciones",  types: ["card_settlement"] },
  { key: "charge",     label: "Cargos",         types: ["fee", "tax_debit", "interest"] },
  { key: "adjustment", label: "Ajustes",        types: ["manual_adjustment"] },
]
