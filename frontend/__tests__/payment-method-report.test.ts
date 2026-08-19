/**
 * metodos-pago-operaciones — mapeo y totales del reporte por forma de pago.
 * Espejo exacto de cost-center-report.test.ts (task 6.1 RED → GREEN → TRIANGULATE).
 *
 * El backend devuelve NUMERIC vía Pydantic float, pero puede llegar como
 * string en algún proxy/serialización intermedia — el mapeo castea siempre.
 * La fila con payment_method_id NULL es contrato (lo no imputado), no un
 * caso borde a descartar.
 */

import { describe, it, expect } from "vitest"
import {
  mapPaymentMethodReportRow,
  sumPaymentMethodReport,
  UNASSIGNED_PAYMENT_METHOD_LABEL,
} from "@/lib/payment-method-report"

describe("mapPaymentMethodReportRow", () => {
  it("mapea una fila con forma de pago imputada, casteando a number", () => {
    const row = mapPaymentMethodReportRow({
      payment_method_id: "pm-1",
      payment_method_name: "Efectivo",
      payment_method_kind: "cash",
      is_active: true,
      total_sold: "15000.00",
      total_purchased: "3000.50",
      operation_count: "3",
    })

    expect(row).toEqual({
      id: "pm-1",
      name: "Efectivo",
      kind: "cash",
      isActive: true,
      totalSold: 15000,
      totalPurchased: 3000.5,
      operationCount: 3,
    })
  })

  it("mapea la fila de no imputados (payment_method_id NULL)", () => {
    const row = mapPaymentMethodReportRow({
      payment_method_id: null,
      payment_method_name: UNASSIGNED_PAYMENT_METHOD_LABEL,
      payment_method_kind: null,
      is_active: true,
      total_sold: "700",
      total_purchased: "0",
      operation_count: "1",
    })

    expect(row.id).toBeNull()
    expect(row.name).toBe("Sin especificar")
    expect(row.kind).toBeNull()
    expect(row.totalSold).toBe(700)
  })

  it("TRIANGULATE: una forma de pago desactivada conserva nombre y queda marcada", () => {
    const row = mapPaymentMethodReportRow({
      payment_method_id: "pm-2",
      payment_method_name: "Cheque",
      payment_method_kind: "check",
      is_active: false,
      total_sold: "0",
      total_purchased: "800",
      operation_count: "1",
    })

    expect(row.name).toBe("Cheque")
    expect(row.isActive).toBe(false)
  })

  it("TRIANGULATE: tolera nulos e indefinidos en los importes", () => {
    const row = mapPaymentMethodReportRow({
      payment_method_id: "pm-3",
      payment_method_name: "Transferencia bancaria",
      payment_method_kind: "transfer",
      is_active: true,
      total_sold: null,
      total_purchased: undefined,
      operation_count: null,
    })

    expect(row.totalSold).toBe(0)
    expect(row.totalPurchased).toBe(0)
    expect(row.operationCount).toBe(0)
  })

  it("TRIANGULATE: sin nombre cae en la etiqueta de no imputado", () => {
    const row = mapPaymentMethodReportRow({
      payment_method_id: null,
      payment_method_name: null,
      payment_method_kind: null,
      is_active: true,
      total_sold: "10",
      total_purchased: "0",
      operation_count: "1",
    })

    expect(row.name).toBe(UNASSIGNED_PAYMENT_METHOD_LABEL)
  })
})

describe("sumPaymentMethodReport", () => {
  it("suma vendido, comprado y operaciones de todas las filas", () => {
    const rows = [
      { totalSold: 15100, totalPurchased: 3000, operationCount: 3 },
      { totalSold: 20000, totalPurchased: 0, operationCount: 1 },
      { totalSold: 700, totalPurchased: 0, operationCount: 1 },
    ].map((r) => ({ id: null, name: "x", kind: null, isActive: true, ...r }))

    expect(sumPaymentMethodReport(rows)).toEqual({
      totalSold: 35800,
      totalPurchased: 3000,
      operationCount: 5,
    })
  })

  it("TRIANGULATE: sin filas los totales son cero, no NaN", () => {
    expect(sumPaymentMethodReport([])).toEqual({
      totalSold: 0,
      totalPurchased: 0,
      operationCount: 0,
    })
  })

  it("la fila de no imputados cuenta en el total del período", () => {
    const rows = [
      { id: "pm-1", name: "Efectivo", kind: "cash" as const, isActive: true, totalSold: 15100, totalPurchased: 3000, operationCount: 3 },
      { id: null, name: UNASSIGNED_PAYMENT_METHOD_LABEL, kind: null, isActive: true, totalSold: 700, totalPurchased: 0, operationCount: 1 },
    ]

    expect(sumPaymentMethodReport(rows).totalSold).toBe(15800)
  })
})
