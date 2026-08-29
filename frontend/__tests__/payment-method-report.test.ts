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
      // gastos-forma-pago (D14): la RPC pasó de 7 a 8 columnas.
      total_spent: "1200.25",
      operation_count: "3",
    })

    expect(row).toEqual({
      id: "pm-1",
      name: "Efectivo",
      kind: "cash",
      isActive: true,
      totalSold: 15000,
      totalPurchased: 3000.5,
      totalSpent: 1200.25,
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
    ].map((r) => ({ id: null, name: "x", kind: null, isActive: true, totalSpent: 0, ...r }))

    expect(sumPaymentMethodReport(rows)).toEqual({
      totalSold: 35800,
      totalPurchased: 3000,
      totalSpent: 0,
      operationCount: 5,
    })
  })

  it("TRIANGULATE: sin filas los totales son cero, no NaN", () => {
    expect(sumPaymentMethodReport([])).toEqual({
      totalSold: 0,
      totalPurchased: 0,
      totalSpent: 0,
      operationCount: 0,
    })
  })

  it("la fila de no imputados cuenta en el total del período", () => {
    const rows = [
      { id: "pm-1", name: "Efectivo", kind: "cash" as const, isActive: true, totalSold: 15100, totalPurchased: 3000, totalSpent: 0, operationCount: 3 },
      { id: null, name: UNASSIGNED_PAYMENT_METHOD_LABEL, kind: null, isActive: true, totalSold: 700, totalPurchased: 0, totalSpent: 0, operationCount: 1 },
    ]

    expect(sumPaymentMethodReport(rows).totalSold).toBe(15800)
  })
})

// ── gastos-forma-pago (D14 / task 11.6): la columna de gastos ──────────────

describe("reporte por forma de pago — columna de gastos (D14)", () => {
  it("mapea `total_spent`, casteando string a number como los otros importes", () => {
    const row = mapPaymentMethodReportRow({
      payment_method_id: "pm-1",
      payment_method_name: "Efectivo",
      payment_method_kind: "cash",
      is_active: true,
      total_sold: "0",
      total_purchased: "0",
      total_spent: "6000.00",
      operation_count: "2",
    })

    expect(row.totalSpent).toBe(6000)
    // Una forma de pago que SÓLO tiene gastos no contamina las otras dos
    // columnas: el reporte dejaría de cerrar contra ventas y compras.
    expect(row.totalSold).toBe(0)
    expect(row.totalPurchased).toBe(0)
  })

  it("una lectura vieja sin `total_spent` degrada a 0, no a NaN", () => {
    // Retrocompatibilidad real: entre el merge y el deploy del backend puede
    // llegar una respuesta de 7 columnas.
    const row = mapPaymentMethodReportRow({
      payment_method_id: "pm-1",
      payment_method_name: "Efectivo",
      payment_method_kind: "cash",
      is_active: true,
      total_sold: "100",
      total_purchased: "0",
      operation_count: "1",
    })

    expect(row.totalSpent).toBe(0)
  })

  it("suma los gastos de todas las filas, incluida la de no imputados", () => {
    const rows = [
      { id: "pm-1", name: "Efectivo", kind: "cash" as const, isActive: true, totalSold: 0, totalPurchased: 0, totalSpent: 6000, operationCount: 2 },
      { id: "pm-2", name: "Transferencia", kind: "transfer" as const, isActive: true, totalSold: 0, totalPurchased: 0, totalSpent: 7000, operationCount: 1 },
      { id: null, name: UNASSIGNED_PAYMENT_METHOD_LABEL, kind: null, isActive: true, totalSold: 0, totalPurchased: 0, totalSpent: 800, operationCount: 1 },
    ]

    // Los mismos números que verifica el gate SQL del change: 6000 + 7000 +
    // 800 = 13800. Los 175 gastos históricos caen en la fila de no imputados,
    // y esconderlos daría un total por debajo del real (D7).
    expect(sumPaymentMethodReport(rows).totalSpent).toBe(13800)
  })
})
