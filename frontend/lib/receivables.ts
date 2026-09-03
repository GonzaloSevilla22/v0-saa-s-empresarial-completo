/**
 * cobranzas-panel + cobranzas-vencimientos — capa canónica de los
 * read-models GET /reports/receivables y GET /reports/payables (backend
 * FastAPI, rpc_receivables_report / rpc_payables_report). Molde de
 * lib/payment-method-report.ts.
 *
 * El mapeo y los totales viven acá (no en la pantalla) para que sean
 * testeables y reutilizables. Invariante D4/OQ-4: `null` en las antigüedades
 * significa "nunca ocurrió" y se PRESERVA como null — jamás degrada a 0 (un
 * cliente que nunca pagó no pagó hoy); la superficie lo muestra como "—".
 * Lo mismo para oldest_due_date/days_overdue_max: null = "sin vencidos".
 */

import type {
  PayableRow,
  PayablesSummary,
  ReceivableRow,
  ReceivablesSummary,
} from "@/lib/types"

/** Fila cruda tal como la devuelve GET /reports/receivables (Decimal → string). */
export interface ReceivableRawRow {
  client_id: string
  client_name: string
  client_phone?: string | null
  balance: string | number
  days_since_last_charge?: number | null
  days_since_last_payment?: number | null
  last_payment_date?: string | null
  // cobranzas-vencimientos: los cinco tramos + agregados de vencimiento.
  overdue_total?: string | number
  amount_current?: string | number
  amount_overdue_1_30?: string | number
  amount_overdue_31_60?: string | number
  amount_overdue_60_plus?: string | number
  amount_no_due_date?: string | number
  oldest_due_date?: string | null
  days_overdue_max?: number | null
}

/** Resumen crudo tal como lo devuelve GET /reports/receivables/summary. */
export interface ReceivablesSummaryRaw {
  total_receivable: string | number
  overdue_total?: string | number
  debtor_count: number
}

/** Envelope estándar del listado (api-standards §2). */
export interface ReceivablePageRaw {
  items: ReceivableRawRow[]
  total: number
  page: number
  pages: number
}

/** Fila cruda de GET /reports/payables — espejo del lado proveedor. */
export interface PayableRawRow {
  supplier_id: string
  supplier_name: string
  balance: string | number
  days_since_last_charge?: number | null
  days_since_last_payment?: number | null
  last_payment_date?: string | null
  overdue_total?: string | number
  amount_current?: string | number
  amount_overdue_1_30?: string | number
  amount_overdue_31_60?: string | number
  amount_overdue_60_plus?: string | number
  amount_no_due_date?: string | number
  oldest_due_date?: string | null
  days_overdue_max?: number | null
}

export interface PayablesSummaryRaw {
  total_payable: string | number
  overdue_total?: string | number
  creditor_count: number
}

export interface PayablePageRaw {
  items: PayableRawRow[]
  total: number
  page: number
  pages: number
}

function toNumber(value: string | number | undefined): number {
  if (value === undefined) return 0
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

export function mapReceivableRow(raw: ReceivableRawRow): ReceivableRow {
  return {
    clientId: raw.client_id,
    clientName: raw.client_name,
    clientPhone: raw.client_phone ?? null,
    balance: toNumber(raw.balance),
    // `?? null` preserva 0 (cargo de hoy) y sólo normaliza undefined → null.
    daysSinceLastCharge: raw.days_since_last_charge ?? null,
    daysSinceLastPayment: raw.days_since_last_payment ?? null,
    lastPaymentDate: raw.last_payment_date ?? null,
    overdueTotal: toNumber(raw.overdue_total),
    amountCurrent: toNumber(raw.amount_current),
    amountOverdue1_30: toNumber(raw.amount_overdue_1_30),
    amountOverdue31_60: toNumber(raw.amount_overdue_31_60),
    amountOverdue60Plus: toNumber(raw.amount_overdue_60_plus),
    amountNoDueDate: toNumber(raw.amount_no_due_date),
    // null = "no hay vencidos abiertos" — se preserva, nunca degrada a 0
    // (un days_overdue_max de 0 no existe: vencido empieza en 1 día).
    oldestDueDate: raw.oldest_due_date ?? null,
    daysOverdueMax: raw.days_overdue_max ?? null,
  }
}

export function mapReceivablesSummary(raw: ReceivablesSummaryRaw): ReceivablesSummary {
  return {
    totalReceivable: toNumber(raw.total_receivable),
    overdueTotal: toNumber(raw.overdue_total),
    debtorCount: raw.debtor_count,
  }
}

export function mapPayableRow(raw: PayableRawRow): PayableRow {
  return {
    supplierId: raw.supplier_id,
    supplierName: raw.supplier_name,
    balance: toNumber(raw.balance),
    daysSinceLastCharge: raw.days_since_last_charge ?? null,
    daysSinceLastPayment: raw.days_since_last_payment ?? null,
    lastPaymentDate: raw.last_payment_date ?? null,
    overdueTotal: toNumber(raw.overdue_total),
    amountCurrent: toNumber(raw.amount_current),
    amountOverdue1_30: toNumber(raw.amount_overdue_1_30),
    amountOverdue31_60: toNumber(raw.amount_overdue_31_60),
    amountOverdue60Plus: toNumber(raw.amount_overdue_60_plus),
    amountNoDueDate: toNumber(raw.amount_no_due_date),
    oldestDueDate: raw.oldest_due_date ?? null,
    daysOverdueMax: raw.days_overdue_max ?? null,
  }
}

export function mapPayablesSummary(raw: PayablesSummaryRaw): PayablesSummary {
  return {
    totalPayable: toNumber(raw.total_payable),
    overdueTotal: toNumber(raw.overdue_total),
    creditorCount: raw.creditor_count,
  }
}

/**
 * Suma de saldos de un conjunto de filas. El total canónico de la cabecera
 * viene de /summary (D2 — mismo RPC); este sumador sirve para asserts y pies
 * de tabla parciales.
 */
export function sumReceivables(rows: ReceivableRow[]): number {
  return rows.reduce((acc, r) => acc + r.balance, 0)
}
