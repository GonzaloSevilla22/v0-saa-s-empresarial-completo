/**
 * cobranzas-panel (task 4.1 RED): mapper y sumador de la capa canónica del
 * read-model de cuentas por cobrar (lib/receivables.ts).
 *
 * Invariantes bajo test:
 * - La fila cruda llega snake_case con el dinero como string (Decimal de
 *   Pydantic v2 serializa a string) y el mapper la convierte al dominio.
 * - `null` en las antigüedades se PRESERVA como null — jamás degrada a 0:
 *   un cliente que nunca pagó no pagó hoy (D4/OQ-4).
 * - `0` días es un valor legítimo (cargo de hoy) y se preserva como 0.
 * - El sumador de totales cierra contra la suma de los saldos.
 */

import { describe, it, expect } from "vitest"
import {
  mapReceivableRow,
  mapReceivablesSummary,
  sumReceivables,
  type ReceivableRawRow,
  type ReceivablesSummaryRaw,
} from "@/lib/receivables"

const RAW_FULL: ReceivableRawRow = {
  client_id: "11111111-1111-1111-1111-111111111111",
  client_name: "Deudor Grande",
  balance: "12500.50",
  days_since_last_charge: 12,
  days_since_last_payment: 30,
  last_payment_date: "2026-08-03",
}

// OQ-4: deuda nacida sólo de un adjustment — sin cargo ni cobro jamás.
const RAW_ADJUSTMENT_ONLY: ReceivableRawRow = {
  client_id: "22222222-2222-2222-2222-222222222222",
  client_name: "Solo Ajuste",
  balance: "3000",
  days_since_last_charge: null,
  days_since_last_payment: null,
  last_payment_date: null,
}

describe("mapReceivableRow", () => {
  it("convierte la fila cruda snake_case con dinero-string al dominio", () => {
    const row = mapReceivableRow(RAW_FULL)

    expect(row.clientId).toBe("11111111-1111-1111-1111-111111111111")
    expect(row.clientName).toBe("Deudor Grande")
    expect(row.balance).toBe(12500.5)
    expect(row.daysSinceLastCharge).toBe(12)
    expect(row.daysSinceLastPayment).toBe(30)
    expect(row.lastPaymentDate).toBe("2026-08-03")
  })

  it("preserva null en las antigüedades — NO degrada a 0 (OQ-4)", () => {
    const row = mapReceivableRow(RAW_ADJUSTMENT_ONLY)

    expect(row.daysSinceLastCharge).toBeNull()
    expect(row.daysSinceLastPayment).toBeNull()
    expect(row.lastPaymentDate).toBeNull()
    expect(row.balance).toBe(3000)
  })

  it("preserva 0 días como 0 (cargo de hoy), distinto de null", () => {
    const row = mapReceivableRow({
      ...RAW_FULL,
      days_since_last_charge: 0,
      days_since_last_payment: 0,
    })

    expect(row.daysSinceLastCharge).toBe(0)
    expect(row.daysSinceLastPayment).toBe(0)
  })

  it("acepta balance numérico además de string", () => {
    const row = mapReceivableRow({ ...RAW_FULL, balance: 999.25 })
    expect(row.balance).toBe(999.25)
  })
})

describe("sumReceivables", () => {
  it("el sumador de totales cierra contra la suma de los saldos", () => {
    const rows = [
      mapReceivableRow({ ...RAW_FULL, balance: "1000" }),
      mapReceivableRow({ ...RAW_ADJUSTMENT_ONLY, balance: "2500" }),
      mapReceivableRow({ ...RAW_FULL, client_id: "3", balance: "400" }),
    ]

    expect(sumReceivables(rows)).toBe(3900)
  })

  it("sin filas suma 0", () => {
    expect(sumReceivables([])).toBe(0)
  })
})

describe("mapReceivablesSummary", () => {
  it("convierte el resumen crudo (dinero como string) al dominio", () => {
    const raw: ReceivablesSummaryRaw = {
      total_receivable: "567000.00",
      debtor_count: 11,
    }

    const summary = mapReceivablesSummary(raw)

    expect(summary.totalReceivable).toBe(567000)
    expect(summary.debtorCount).toBe(11)
  })

  it("resumen vacío mapea a ceros", () => {
    const summary = mapReceivablesSummary({ total_receivable: "0", debtor_count: 0 })

    expect(summary.totalReceivable).toBe(0)
    expect(summary.debtorCount).toBe(0)
  })
})
