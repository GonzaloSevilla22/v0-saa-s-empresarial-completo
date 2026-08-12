/**
 * Test de paridad entre los dos módulos canónicos de reporting
 * (kpi-ia-canonical-revenue, D3): `frontend/lib/reporting/revenue-canon.ts`
 * (Next.js) y `supabase/functions/_shared/reporting-canon.ts` (Deno).
 *
 * Una única tabla de casos, ejecutada contra las dos implementaciones, con
 * assert de igualdad resultado a resultado. Si un solo caso difiere entre
 * las dos copias, este test se pone rojo — es la mitigación completa del
 * riesgo de divergencia silenciosa entre runtimes (D3).
 */

import { describe, it, expect } from "vitest"
import * as frontendCanon from "@/lib/reporting/revenue-canon"
import * as edgeCanon from "../../../supabase/functions/_shared/reporting-canon"

// ─── Tabla de casos compartida ─────────────────────────────────────────────────

const lineRevenueCases: Array<{
  name: string
  row: { amount: number | string | null; total?: number | string | null }
  expected: number
}> = [
  { name: "multi-unidad usa total de línea", row: { amount: 1000, total: 3000 }, expected: 3000 },
  { name: "legacy sin total usa amount", row: { amount: 500, total: null }, expected: 500 },
  { name: "total = 0 legítimo no cae al fallback", row: { amount: 900, total: 0 }, expected: 0 },
  { name: "numerics como string sin pérdida de decimales", row: { amount: "1000", total: "1500.50" }, expected: 1500.5 },
  { name: "amount y total ambos NULL → 0", row: { amount: null, total: null }, expected: 0 },
  { name: "sin campo total → usa amount", row: { amount: 250 }, expected: 250 },
]

const netMarginCases: Array<{
  name: string
  netProfit: number | null
  revenue: number | null
  expected: number | null
}> = [
  { name: "caso normal", netProfit: 4000, revenue: 9000, expected: 44 },
  { name: "revenue 0 → null", netProfit: 4000, revenue: 0, expected: null },
  { name: "revenue negativo → null", netProfit: 4000, revenue: -100, expected: null },
  { name: "revenue null → null", netProfit: 4000, revenue: null, expected: null },
  { name: "ganancia negativa se informa", netProfit: -1000, revenue: 5000, expected: -20 },
  { name: "netProfit null → null", netProfit: null, revenue: 9000, expected: null },
]

const previousWindowCases: Array<{ name: string; from: string; to: string }> = [
  { name: "mes completo", from: "2026-07-01T00:00:00.000Z", to: "2026-07-31T23:59:59.999Z" },
  { name: "30 días", from: "2026-07-12T00:00:00.000Z", to: "2026-08-11T00:00:00.000Z" },
  { name: "1 día", from: "2026-08-11T00:00:00.000Z", to: "2026-08-11T23:59:59.999Z" },
]

// ─── Paridad ──────────────────────────────────────────────────────────────────

describe("paridad frontend <-> Deno: lineRevenue", () => {
  for (const c of lineRevenueCases) {
    it(`${c.name} — ambas implementaciones coinciden`, () => {
      const frontendResult = frontendCanon.lineRevenue(c.row)
      const edgeResult = edgeCanon.lineRevenue(c.row)
      expect(frontendResult).toBe(c.expected)
      expect(edgeResult).toBe(c.expected)
      expect(frontendResult).toBe(edgeResult)
    })
  }
})

describe("paridad frontend <-> Deno: netMarginPct", () => {
  for (const c of netMarginCases) {
    it(`${c.name} — ambas implementaciones coinciden`, () => {
      const frontendResult = frontendCanon.netMarginPct(c.netProfit, c.revenue)
      const edgeResult = edgeCanon.netMarginPct(c.netProfit, c.revenue)
      expect(frontendResult).toBe(c.expected)
      expect(edgeResult).toBe(c.expected)
      expect(frontendResult).toBe(edgeResult)
    })
  }
})

describe("paridad frontend <-> Deno: previousWindow", () => {
  for (const c of previousWindowCases) {
    it(`${c.name} — ambas implementaciones coinciden`, () => {
      const frontendResult = frontendCanon.previousWindow(c.from, c.to)
      const edgeResult = edgeCanon.previousWindow(c.from, c.to)
      expect(frontendResult).toEqual(edgeResult)
    })
  }
})
