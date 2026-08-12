import { describe, it, expect, vi, afterEach } from "vitest"
import { parseDate } from "@/lib/excel"

// app-timezone-argentina, task 2.4: el fallback "hoy" de parseDate (usado por
// el importador de gastos vía expense-import-dialog.tsx) debe resolver al día
// ARGENTINO, no al día UTC del server.

describe("parseDate — fallback a hoy (app-timezone-argentina)", () => {
  afterEach(() => {
    vi.useRealTimers()
  })

  it("REGRESSION: a las 22:00 ART, el fallback es HOY (día D), no mañana (día UTC D+1)", () => {
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-09T01:00:00.000Z")) // 22:00 ART, 8/jun
    expect(parseDate(undefined)).toBe("2026-06-08")
    expect(parseDate("")).toBe("2026-06-08")
    expect(parseDate("no-reconocida")).toBe("2026-06-08")
  })

  it("un ISO válido no se toca (no pasa por el fallback)", () => {
    expect(parseDate("2026-05-01")).toBe("2026-05-01")
  })

  it("un dd/mm/yyyy válido se normaliza a ISO", () => {
    expect(parseDate("01/05/2026")).toBe("2026-05-01")
  })
})
