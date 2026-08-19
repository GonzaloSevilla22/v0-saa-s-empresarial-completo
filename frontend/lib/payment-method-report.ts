/**
 * metodos-pago-operaciones — lectura del read-model GET /reports/payment-methods
 * (backend FastAPI, rpc_payment_method_report). Espejo de lib/cost-center-report.ts.
 *
 * Capa canónica del reporte: el mapeo y los totales viven acá (no en la
 * pantalla) para que sean testeables y reutilizables.
 *
 * A diferencia del reporte de centros de costo (que el frontend consulta
 * directo vía supabase.rpc), este reporte pasa por el backend (design.md
 * task 4.6 / Requirement "Endpoints de formas de pago en el backend") — la
 * fila `id = null` sigue siendo el contrato: son las operaciones del período
 * que nunca se imputaron, y excluirla mostraría un total por debajo del real.
 */

import type { PaymentMethodReportRow } from "@/lib/types"

export const UNASSIGNED_PAYMENT_METHOD_LABEL = "Sin especificar"

/** Fila cruda tal como la devuelve GET /reports/payment-methods. */
export interface PaymentMethodReportRawRow {
  payment_method_id?: string | null
  payment_method_name?: string | null
  payment_method_kind?: string | null
  is_active?: boolean | null
  total_sold?: string | number | null
  total_purchased?: string | number | null
  operation_count?: string | number | null
}

function toNumber(value: string | number | null | undefined): number {
  if (value === null || value === undefined) return 0
  const parsed = typeof value === "number" ? value : Number(value)
  return Number.isFinite(parsed) ? parsed : 0
}

export function mapPaymentMethodReportRow(raw: PaymentMethodReportRawRow): PaymentMethodReportRow {
  return {
    id:              raw.payment_method_id ?? null,
    name:            raw.payment_method_name ?? UNASSIGNED_PAYMENT_METHOD_LABEL,
    kind:            (raw.payment_method_kind ?? null) as PaymentMethodReportRow["kind"],
    isActive:        raw.is_active ?? true,
    totalSold:       toNumber(raw.total_sold),
    totalPurchased:  toNumber(raw.total_purchased),
    operationCount:  toNumber(raw.operation_count),
  }
}

export interface PaymentMethodReportTotals {
  totalSold: number
  totalPurchased: number
  operationCount: number
}

/**
 * Totales del período. Suma TODAS las filas, incluida la de no imputados: el
 * pie de la tabla tiene que cerrar contra el total real del período.
 */
export function sumPaymentMethodReport(rows: PaymentMethodReportRow[]): PaymentMethodReportTotals {
  return rows.reduce<PaymentMethodReportTotals>(
    (acc, r) => ({
      totalSold:      acc.totalSold      + r.totalSold,
      totalPurchased: acc.totalPurchased + r.totalPurchased,
      operationCount: acc.operationCount + r.operationCount,
    }),
    { totalSold: 0, totalPurchased: 0, operationCount: 0 },
  )
}
