/**
 * v31-ia-ratelimit-budget (D8, task 4.1): `nextAiResetDate` es la MISMA regla que
 * `rpc_reserve_ai_usage` (reset_at) y el cron `reset-ai-counters`: el día 1 del mes
 * siguiente a las 00:00 UTC. En el instante exacto del reset el cron ya corrió, así que
 * la próxima renovación es la del mes que sigue.
 */
import { describe, it, expect } from "vitest"
import { nextAiResetDate, formatAiResetDate } from "@/lib/ai-usage"

describe("nextAiResetDate", () => {
  it("a mediados de mes devuelve el día 1 del mes siguiente 00:00 UTC", () => {
    expect(nextAiResetDate(new Date("2026-11-15T13:45:10.000Z")).toISOString()).toBe("2026-12-01T00:00:00.000Z")
  })

  it("el 31 de diciembre salta de año", () => {
    expect(nextAiResetDate(new Date("2026-12-31T23:59:59.999Z")).toISOString()).toBe("2027-01-01T00:00:00.000Z")
  })

  it("un instante antes del reset todavía apunta a ese reset", () => {
    expect(nextAiResetDate(new Date("2026-11-30T23:59:59.999Z")).toISOString()).toBe("2026-12-01T00:00:00.000Z")
  })

  it("en el instante exacto del reset ya apunta al mes que sigue", () => {
    expect(nextAiResetDate(new Date("2026-12-01T00:00:00.000Z")).toISOString()).toBe("2027-01-01T00:00:00.000Z")
  })

  it("usa el mes UTC, no el local: 1 de enero 02:00 UTC sigue siendo enero", () => {
    expect(nextAiResetDate(new Date("2027-01-01T02:00:00.000Z")).toISOString()).toBe("2027-02-01T00:00:00.000Z")
  })
})

describe("formatAiResetDate (es-AR)", () => {
  it("formatea día y mes en español sin correrse por la zona horaria", () => {
    expect(formatAiResetDate(new Date("2026-12-01T00:00:00.000Z"))).toBe("1 de diciembre")
  })

  it("triangulación: otro mes", () => {
    expect(formatAiResetDate(new Date("2027-03-01T00:00:00.000Z"))).toBe("1 de marzo")
  })
})
