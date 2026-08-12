import { describe, it, expect, vi, afterEach } from "vitest"
import {
  argentinaToday,
  argentinaDaysAgo,
  argentinaDayCases,
  utcDayRange,
  utcMonthRange,
  utcPrevMonthRange,
  monthKey,
  parseMonthKey,
} from "@/lib/date-range"

// app-timezone-argentina: the app's business day is Argentina's calendar day
// (America/Argentina/Mendoza, UTC-3, sin DST). Every helper here derives its
// Y/M/D from the instant's Argentina calendar date via Intl.DateTimeFormat
// (D1) — never from the runtime's local clock and never from a hardcoded -3
// offset. Inputs are ALWAYS built from absolute ISO instants with `Z` so the
// suite is deterministic in any runtime timezone (CI runs UTC, dev machines
// may run ART) — never `new Date()` without an argument inside an assert.

describe("argentinaToday", () => {
  for (const c of argentinaDayCases) {
    it(c.name, () => {
      expect(argentinaToday(new Date(c.instantIso))).toBe(c.expectedDay)
    })
  }
})

describe("argentinaDaysAgo", () => {
  it("0 días atrás es lo mismo que argentinaToday", () => {
    const instant = new Date("2026-06-17T15:00:00.000Z") // 12:00 ART
    expect(argentinaDaysAgo(0, instant)).toBe(argentinaToday(instant))
  })

  it("30 días atrás cruza un borde de mes", () => {
    // 17 de junio ART (12:00) menos 30 días = 18 de mayo
    expect(argentinaDaysAgo(30, new Date("2026-06-17T15:00:00.000Z"))).toBe("2026-05-18")
  })

  it("respeta el borde nocturno: a las 21:00 ART del día D, 1 día atrás es D-1 (no D)", () => {
    // 21:00 ART del 8/jun (bug clásico: UTC ya es 9/jun)
    expect(argentinaDaysAgo(1, new Date("2026-06-09T00:00:00.000Z"))).toBe("2026-06-07")
  })
})

describe("utcDayRange", () => {
  it("returns a UTC-midnight..end-of-day window for the Argentina calendar date", () => {
    const { from, to } = utcDayRange(new Date("2026-06-08T15:00:00.000Z")) // 12:00 ART, 8/jun
    expect(from).toBe("2026-06-08T00:00:00.000Z")
    expect(to).toBe("2026-06-08T23:59:59.999Z")
  })

  it("REGRESSION: 21:00 ART still resolves to day D, not UTC's D+1", () => {
    // El bug original: una venta cargada a las 22:00 ART se guardaba con
    // fecha de mañana porque el server (UTC) ya había rolleado el día.
    const { from } = utcDayRange(new Date("2026-06-09T00:00:00.000Z")) // 21:00 ART, 8/jun
    expect(from.startsWith("2026-06-08")).toBe(true)
  })

  it("REGRESSION: a sale stored at midnight UTC falls inside that day's window", () => {
    const { from, to } = utcDayRange(new Date("2026-06-09T00:48:00.000Z")) // 21:48 ART, 8/jun
    const saleStoredAtMidnightUtc = "2026-06-08T00:00:00.000Z"
    expect(from <= saleStoredAtMidnightUtc && saleStoredAtMidnightUtc <= to).toBe(true)
  })

  it("does NOT shift the calendar date forward late in the evening (23:30 ART)", () => {
    const { from } = utcDayRange(new Date("2026-06-09T02:30:00.000Z")) // 23:30 ART, 8/jun
    expect(from.startsWith("2026-06-08")).toBe(true)
  })
})

describe("utcMonthRange", () => {
  it("spans the first to the last day of the Argentina month", () => {
    const { from, to } = utcMonthRange(new Date("2026-06-17T15:00:00.000Z")) // June 2026, ART
    expect(from).toBe("2026-06-01T00:00:00.000Z")
    expect(to).toBe("2026-06-30T23:59:59.999Z")
  })

  it("handles February in a non-leap year (28 days)", () => {
    const { from, to } = utcMonthRange(new Date("2026-02-10T15:00:00.000Z")) // Feb 2026, ART
    expect(from).toBe("2026-02-01T00:00:00.000Z")
    expect(to).toBe("2026-02-28T23:59:59.999Z")
  })

  it("handles December (next-month rollover for the end boundary)", () => {
    const { from, to } = utcMonthRange(new Date("2026-12-05T15:00:00.000Z")) // Dec 2026, ART
    expect(from).toBe("2026-12-01T00:00:00.000Z")
    expect(to).toBe("2026-12-31T23:59:59.999Z")
  })

  it("REGRESSION: 21:00 ART on the last day of May still resolves to May, not June", () => {
    const { from, to } = utcMonthRange(new Date("2026-06-01T00:00:00.000Z")) // 21:00 ART, 31/may
    expect(from).toBe("2026-05-01T00:00:00.000Z")
    expect(to).toBe("2026-05-31T23:59:59.999Z")
  })
})

describe("monthKey / parseMonthKey", () => {
  it("monthKey produce YYYY-MM del día argentino", () => {
    expect(monthKey(new Date("2026-06-17T15:00:00.000Z"))).toBe("2026-06")
    expect(monthKey(new Date("2026-01-03T15:00:00.000Z"))).toBe("2026-01")
  })

  it("REGRESSION: monthKey a las 21:00 ART del 31/may sigue en mayo", () => {
    expect(monthKey(new Date("2026-06-01T00:00:00.000Z"))).toBe("2026-05")
  })

  it("parseMonthKey devuelve un valor que monthKey vuelve a leer como el mismo mes", () => {
    const d = parseMonthKey("2026-05")
    expect(monthKey(d)).toBe("2026-05")
  })

  it("parseMonthKey con input inválido o null cae al mes argentino actual", () => {
    // 22:00 ART del 31/may (bug window: UTC ya es 1/jun) — el fallback debe
    // resolver a mayo, no a junio.
    vi.useFakeTimers()
    vi.setSystemTime(new Date("2026-06-01T01:00:00.000Z"))
    try {
      for (const bad of [null, "", "junio", "2026-13", "26-05"]) {
        const d = parseMonthKey(bad)
        expect(monthKey(d)).toBe("2026-05")
      }
    } finally {
      vi.useRealTimers()
    }
  })

  it("roundtrip: monthKey(parseMonthKey(monthKey(d))) conserva año y mes", () => {
    const d = new Date("2025-12-31T15:00:00.000Z") // 12:00 ART, 31/dic/2025
    const key = monthKey(d)
    expect(key).toBe("2025-12")
    expect(monthKey(parseMonthKey(key))).toBe(key)
  })
})

afterEach(() => {
  vi.useRealTimers()
})

describe("utcPrevMonthRange", () => {
  it("returns the previous calendar month", () => {
    const { from, to } = utcPrevMonthRange(new Date("2026-06-17T15:00:00.000Z")) // June -> May
    expect(from).toBe("2026-05-01T00:00:00.000Z")
    expect(to).toBe("2026-05-31T23:59:59.999Z")
  })

  it("rolls back across the year boundary (January -> previous December)", () => {
    const { from, to } = utcPrevMonthRange(new Date("2026-01-09T15:00:00.000Z")) // Jan 2026 -> Dec 2025
    expect(from).toBe("2025-12-01T00:00:00.000Z")
    expect(to).toBe("2025-12-31T23:59:59.999Z")
  })

  it("REGRESSION: 21:00 ART on 31/dic still resolves the previous month as November", () => {
    const { from, to } = utcPrevMonthRange(new Date("2026-01-01T00:00:00.000Z")) // 21:00 ART, 31/dic/2025
    expect(from).toBe("2025-11-01T00:00:00.000Z")
    expect(to).toBe("2025-11-30T23:59:59.999Z")
  })
})
