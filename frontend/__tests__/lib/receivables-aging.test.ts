/**
 * cobranzas-vencimientos (tasks 8.1/8.3) — capa canónica del aging.
 *
 * - El mapper convierte la fila cruda (snake_case, dinero como string) al
 *   tipo del dominio; `null` en vencimientos y días se PRESERVA y no degrada
 *   a 0 ("no aplica" y "al día" son cosas distintas).
 * - El clasificador de tramo devuelve "sin vencimiento" para vencimiento
 *   ausente — NUNCA "al día" (D5: plegar sería afirmar lo que no se sabe).
 * - El formateador de estado habla en TEXTO (D15) — nunca sólo color.
 * - debt-reminder: función PURA que arma el texto del recordatorio de
 *   WhatsApp y reutiliza buildWhatsAppUrl (nada de normalizadores nuevos).
 *
 * Run: pnpm vitest run __tests__/lib/receivables-aging.test.ts
 */

import { describe, it, expect } from "vitest"
import { mapReceivableRow, type ReceivableRawRow } from "@/lib/receivables"
import {
  classifyWorstBucket,
  AGING_BUCKET_LABELS,
  formatDueStatus,
  formatMovementDueStatus,
} from "@/lib/receivables-aging"
import { buildDebtReminderMessage, buildDebtReminderUrl } from "@/lib/debt-reminder"

const BASE_RAW: ReceivableRawRow = {
  client_id: "c1",
  client_name: "Deudor",
  client_phone: "261 555-1234",
  balance: "2500.00",
  days_since_last_charge: 12,
  days_since_last_payment: null,
  last_payment_date: null,
  overdue_total: "1500.00",
  amount_current: "300.00",
  amount_overdue_1_30: "1000.00",
  amount_overdue_31_60: "500.00",
  amount_overdue_60_plus: "0",
  amount_no_due_date: "700.00",
  oldest_due_date: "2026-07-20",
  days_overdue_max: 44,
}

describe("mapReceivableRow — aging (task 8.1)", () => {
  it("convierte los tramos de string a number", () => {
    const row = mapReceivableRow(BASE_RAW)
    expect(row.overdueTotal).toBe(1500)
    expect(row.amountCurrent).toBe(300)
    expect(row.amountOverdue1_30).toBe(1000)
    expect(row.amountOverdue31_60).toBe(500)
    expect(row.amountOverdue60Plus).toBe(0)
    expect(row.amountNoDueDate).toBe(700)
    expect(row.daysOverdueMax).toBe(44)
    expect(row.oldestDueDate).toBe("2026-07-20")
    expect(row.clientPhone).toBe("261 555-1234")
  })

  it("preserva null en vencimientos y días — NO degrada a 0", () => {
    const row = mapReceivableRow({
      ...BASE_RAW,
      oldest_due_date: null,
      days_overdue_max: null,
    })
    expect(row.oldestDueDate).toBeNull()
    expect(row.daysOverdueMax).toBeNull()
  })

  it("una fila sin campos de aging (respuesta vieja) degrada a 0 en importes y null en fechas", () => {
    const legacy: ReceivableRawRow = {
      client_id: "c2",
      client_name: "Legacy",
      balance: 100,
    }
    const row = mapReceivableRow(legacy)
    expect(row.overdueTotal).toBe(0)
    expect(row.oldestDueDate).toBeNull()
    expect(row.daysOverdueMax).toBeNull()
    expect(row.clientPhone).toBeNull()
  })
})

describe("classifyWorstBucket (task 8.1 — D5)", () => {
  it("elige el tramo vencido más severo con importe abierto", () => {
    expect(classifyWorstBucket(mapReceivableRow(BASE_RAW))).toBe("overdue_31_60")
  })

  it("+60 gana a todos", () => {
    const row = mapReceivableRow({ ...BASE_RAW, amount_overdue_60_plus: "10" })
    expect(classifyWorstBucket(row)).toBe("overdue_60_plus")
  })

  it("sin nada vencido pero con deuda al día → current", () => {
    const row = mapReceivableRow({
      ...BASE_RAW,
      overdue_total: "0",
      amount_overdue_1_30: "0",
      amount_overdue_31_60: "0",
      amount_overdue_60_plus: "0",
      amount_current: "300",
      amount_no_due_date: "0",
    })
    expect(classifyWorstBucket(row)).toBe("current")
  })

  it("deuda SOLO sin vencimiento → no_due_date, NUNCA current", () => {
    const row = mapReceivableRow({
      ...BASE_RAW,
      overdue_total: "0",
      amount_current: "0",
      amount_overdue_1_30: "0",
      amount_overdue_31_60: "0",
      amount_overdue_60_plus: "0",
      amount_no_due_date: "700",
    })
    expect(classifyWorstBucket(row)).toBe("no_due_date")
  })

  it("los cinco tramos tienen rótulo en castellano", () => {
    for (const label of Object.values(AGING_BUCKET_LABELS)) {
      expect(label.length).toBeGreaterThan(0)
    }
    expect(AGING_BUCKET_LABELS.no_due_date.toLowerCase()).toContain("sin vencimiento")
  })
})

describe("formatDueStatus (task 8.2 — D15, texto, nunca sólo color)", () => {
  it("vencido: texto con los días", () => {
    const row = mapReceivableRow(BASE_RAW)
    expect(formatDueStatus(row)).toBe("Vencido hace 44 días")
  })

  it("vencido hace 1 día en singular", () => {
    const row = mapReceivableRow({ ...BASE_RAW, days_overdue_max: 1 })
    expect(formatDueStatus(row)).toBe("Vencido hace 1 día")
  })

  it("sin vencido y con deuda al día → Al día", () => {
    const row = mapReceivableRow({
      ...BASE_RAW,
      overdue_total: "0",
      days_overdue_max: null,
      amount_current: "300",
      amount_no_due_date: "0",
      amount_overdue_1_30: "0",
      amount_overdue_31_60: "0",
      amount_overdue_60_plus: "0",
    })
    expect(formatDueStatus(row)).toBe("Al día")
  })

  it("deuda sólo sin vencimiento → Sin vencimiento (jamás Al día)", () => {
    const row = mapReceivableRow({
      ...BASE_RAW,
      overdue_total: "0",
      days_overdue_max: null,
      amount_current: "0",
      amount_overdue_1_30: "0",
      amount_overdue_31_60: "0",
      amount_overdue_60_plus: "0",
      amount_no_due_date: "700",
    })
    expect(formatDueStatus(row)).toBe("Sin vencimiento")
  })
})

describe("formatMovementDueStatus (task 9.8 — historial por movimiento)", () => {
  it("cargo vencido con abierto: texto con días y saldo", () => {
    expect(
      formatMovementDueStatus({ isOverdue: true, daysOverdue: 45, openAmount: 600 }),
    ).toBe("Vencido hace 45 días")
  })

  it("cargo con vencimiento futuro: al día", () => {
    expect(
      formatMovementDueStatus({ isOverdue: false, daysOverdue: null, openAmount: 500 }),
    ).toBe("Al día")
  })

  it("cargo saldado: Cancelado", () => {
    expect(
      formatMovementDueStatus({ isOverdue: false, daysOverdue: null, openAmount: 0 }),
    ).toBe("Cancelado")
  })

  it("movimiento que no es cargo (derivados ausentes): sin estado", () => {
    expect(
      formatMovementDueStatus({ isOverdue: null, daysOverdue: null, openAmount: null }),
    ).toBeNull()
  })
})

describe("buildDebtReminderMessage (task 8.3 — función pura)", () => {
  const row = mapReceivableRow(BASE_RAW)

  it("incluye nombre, saldo e importe vencido", () => {
    const msg = buildDebtReminderMessage(row)
    expect(msg).toContain("Deudor")
    expect(msg).toContain("2.500")
    expect(msg).toContain("1.500")
  })

  it("menciona el estado de vencimiento cuando existe", () => {
    const msg = buildDebtReminderMessage(row)
    expect(msg.toLowerCase()).toContain("vencid")
  })

  it("sin importe vencido no habla de mora", () => {
    const noOverdue = mapReceivableRow({
      ...BASE_RAW,
      overdue_total: "0",
      days_overdue_max: null,
    })
    const msg = buildDebtReminderMessage(noOverdue)
    expect(msg.toLowerCase()).not.toContain("vencid")
    expect(msg).toContain("2.500")
  })

  it("la URL usa buildWhatsAppUrl con el teléfono normalizado", () => {
    const url = buildDebtReminderUrl(row)
    expect(url).toMatch(/^https:\/\/wa\.me\/549261/)
    expect(url).toContain("text=")
  })

  it("sin teléfono utilizable cae al selector de contactos (no queda inoperante)", () => {
    const noPhone = mapReceivableRow({ ...BASE_RAW, client_phone: null })
    const url = buildDebtReminderUrl(noPhone)
    expect(url).toMatch(/^https:\/\/wa\.me\/\?text=/)
  })
})
