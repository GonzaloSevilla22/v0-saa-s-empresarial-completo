/**
 * cobranzas-vencimientos (task 8.2) — vocabulario canónico del aging.
 *
 * Tramos, rótulos y formateadores de estado EN TEXTO (D15: el color nunca es
 * el único canal). La clasificación por tramo replica el contrato del
 * servidor (rpc_receivables_report): sólo un cargo con vencimiento puede
 * estar vencido; "sin vencimiento" es un tramo propio y JAMÁS se pliega a
 * "al día" (D5 — afirmar que alguien está al día sobre deuda cuyo plazo
 * nadie pactó es una afirmación que el sistema no puede sostener).
 */

import type { ReceivableRow, PayableRow } from "@/lib/types"

/** Los cinco tramos — espejo del Literal del backend. */
export type AgingBucket =
  | "current"
  | "overdue_1_30"
  | "overdue_31_60"
  | "overdue_60_plus"
  | "no_due_date"

/** Filtro del panel: los cinco tramos + el agregado "vencido". */
export type AgingBucketFilter = AgingBucket | "overdue"

export const AGING_BUCKET_LABELS: Record<AgingBucket, string> = {
  current: "Al día",
  overdue_1_30: "Vencido 1-30 días",
  overdue_31_60: "Vencido 31-60 días",
  overdue_60_plus: "Vencido +60 días",
  no_due_date: "Sin vencimiento",
}

export const AGING_FILTER_LABELS: Record<AgingBucketFilter, string> = {
  overdue: "Vencidos",
  ...AGING_BUCKET_LABELS,
}

/** Fila con tramos — lo que comparten ReceivableRow y PayableRow. */
export type AgingRow = Pick<
  ReceivableRow | PayableRow,
  | "overdueTotal"
  | "amountCurrent"
  | "amountOverdue1_30"
  | "amountOverdue31_60"
  | "amountOverdue60Plus"
  | "amountNoDueDate"
  | "daysOverdueMax"
>

/**
 * Tramo más severo con importe abierto de una fila. Orden de severidad:
 * +60 > 31-60 > 1-30 > al día > sin vencimiento. Una fila con deuda SÓLO
 * sin vencimiento clasifica "no_due_date" — nunca "current" (D5).
 */
export function classifyWorstBucket(row: AgingRow): AgingBucket {
  if (row.amountOverdue60Plus > 0) return "overdue_60_plus"
  if (row.amountOverdue31_60 > 0) return "overdue_31_60"
  if (row.amountOverdue1_30 > 0) return "overdue_1_30"
  if (row.amountCurrent > 0) return "current"
  return "no_due_date"
}

/**
 * Estado de vencimiento de la fila, en texto (D15). "Vencido hace N días"
 * usa el atraso máximo entre los cargos abiertos.
 */
export function formatDueStatus(row: AgingRow): string {
  if (row.overdueTotal > 0) {
    const days = row.daysOverdueMax
    if (days !== null && days > 0) {
      return days === 1 ? "Vencido hace 1 día" : `Vencido hace ${days} días`
    }
    return "Vencido"
  }
  if (row.amountCurrent > 0) return "Al día"
  return "Sin vencimiento"
}

/** Derivados de vencimiento de UN movimiento del historial (D7). */
export interface MovementDueInfo {
  isOverdue: boolean | null
  daysOverdue: number | null
  openAmount: number | null
}

/**
 * Estado de vencimiento de un movimiento del historial, en texto — o null
 * cuando el movimiento no es un cargo (derivados ausentes: "no aplica" no es
 * un estado, es la ausencia de uno).
 */
export function formatMovementDueStatus(info: MovementDueInfo): string | null {
  if (info.openAmount === null) return null
  if (info.openAmount === 0) return "Cancelado"
  if (info.isOverdue) {
    const days = info.daysOverdue
    if (days !== null && days > 0) {
      return days === 1 ? "Vencido hace 1 día" : `Vencido hace ${days} días`
    }
    return "Vencido"
  }
  if (info.isOverdue === false) return "Al día"
  return "Sin vencimiento"
}
