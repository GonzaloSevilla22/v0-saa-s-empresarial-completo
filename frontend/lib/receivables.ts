/**
 * cobranzas-panel — capa canónica del read-model GET /reports/receivables
 * (backend FastAPI, rpc_receivables_report). Molde de lib/payment-method-report.ts.
 *
 * El mapeo y los totales viven acá (no en la pantalla) para que sean
 * testeables y reutilizables. Invariante D4/OQ-4: `null` en las antigüedades
 * significa "nunca ocurrió" y se PRESERVA como null — jamás degrada a 0 (un
 * cliente que nunca pagó no pagó hoy); la superficie lo muestra como "—".
 */

import type { ReceivableRow, ReceivablesSummary } from "@/lib/types"

/** Fila cruda tal como la devuelve GET /reports/receivables (Decimal → string). */
export interface ReceivableRawRow {
  client_id: string
  client_name: string
  balance: string | number
  days_since_last_charge?: number | null
  days_since_last_payment?: number | null
  last_payment_date?: string | null
}

/** Resumen crudo tal como lo devuelve GET /reports/receivables/summary. */
export interface ReceivablesSummaryRaw {
  total_receivable: string | number
  debtor_count: number
}

/** Envelope estándar del listado (api-standards §2). */
export interface ReceivablePageRaw {
  items: ReceivableRawRow[]
  total: number
  page: number
  pages: number
}

function toNumber(value: string | number): number {
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

export function mapReceivableRow(raw: ReceivableRawRow): ReceivableRow {
  return {
    clientId: raw.client_id,
    clientName: raw.client_name,
    balance: toNumber(raw.balance),
    // `?? null` preserva 0 (cargo de hoy) y sólo normaliza undefined → null.
    daysSinceLastCharge: raw.days_since_last_charge ?? null,
    daysSinceLastPayment: raw.days_since_last_payment ?? null,
    lastPaymentDate: raw.last_payment_date ?? null,
  }
}

export function mapReceivablesSummary(raw: ReceivablesSummaryRaw): ReceivablesSummary {
  return {
    totalReceivable: toNumber(raw.total_receivable),
    debtorCount: raw.debtor_count,
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
