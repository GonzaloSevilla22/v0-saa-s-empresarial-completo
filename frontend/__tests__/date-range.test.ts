import { describe, it, expect } from "vitest"
import {
  utcDayRange,
  utcMonthRange,
  utcPrevMonthRange,
  monthKey,
  parseMonthKey,
} from "@/lib/date-range"

// These helpers exist to fix the dashboard "$0 today" bug: sale/expense/purchase
// `date` values are stored at MIDNIGHT UTC keyed to a calendar date, so the
// dashboard window must be UTC-midnight based on the user's LOCAL calendar date.
// Inputs are built with the LOCAL Date constructor so getFullYear/Month/Date are
// deterministic regardless of the test runner's timezone.

describe("utcDayRange", () => {
  it("returns a UTC-midnight..end-of-day window for the local calendar date", () => {
    const { from, to } = utcDayRange(new Date(2026, 5, 8, 14, 30, 0)) // local 2026-06-08
    expect(from).toBe("2026-06-08T00:00:00.000Z")
    expect(to).toBe("2026-06-08T23:59:59.999Z")
  })

  it("REGRESSION: a sale stored at midnight UTC falls inside that day's window", () => {
    const { from, to } = utcDayRange(new Date(2026, 5, 8, 21, 48, 0)) // evening, local June 8
    const saleStoredAtMidnightUtc = "2026-06-08T00:00:00.000Z"
    expect(from <= saleStoredAtMidnightUtc && saleStoredAtMidnightUtc <= to).toBe(true)
  })

  it("does NOT shift the calendar date forward in the evening (local late-day instant)", () => {
    // 23:30 local on June 8 must still produce the June 8 UTC window, not June 9.
    const { from } = utcDayRange(new Date(2026, 5, 8, 23, 30, 0))
    expect(from.startsWith("2026-06-08")).toBe(true)
  })
})

describe("utcMonthRange", () => {
  it("spans the first to the last day of the local month, at UTC", () => {
    const { from, to } = utcMonthRange(new Date(2026, 5, 17)) // June 2026
    expect(from).toBe("2026-06-01T00:00:00.000Z")
    expect(to).toBe("2026-06-30T23:59:59.999Z")
  })

  it("handles February in a non-leap year (28 days)", () => {
    const { from, to } = utcMonthRange(new Date(2026, 1, 10)) // Feb 2026
    expect(from).toBe("2026-02-01T00:00:00.000Z")
    expect(to).toBe("2026-02-28T23:59:59.999Z")
  })

  it("handles December (next-month rollover for the end boundary)", () => {
    const { from, to } = utcMonthRange(new Date(2026, 11, 5)) // Dec 2026
    expect(from).toBe("2026-12-01T00:00:00.000Z")
    expect(to).toBe("2026-12-31T23:59:59.999Z")
  })
})

describe("monthKey / parseMonthKey", () => {
  it("monthKey produce YYYY-MM de la fecha local", () => {
    expect(monthKey(new Date(2026, 5, 17))).toBe("2026-06")
    expect(monthKey(new Date(2026, 0, 3))).toBe("2026-01")
  })

  it("parseMonthKey devuelve el primer día del mes (fecha local)", () => {
    const d = parseMonthKey("2026-05")
    expect(d.getFullYear()).toBe(2026)
    expect(d.getMonth()).toBe(4)
    expect(d.getDate()).toBe(1)
  })

  it("parseMonthKey con input inválido o null cae al mes actual", () => {
    const now = new Date()
    for (const bad of [null, "", "junio", "2026-13", "26-05"]) {
      const d = parseMonthKey(bad)
      expect(d.getFullYear()).toBe(now.getFullYear())
      expect(d.getMonth()).toBe(now.getMonth())
    }
  })

  it("roundtrip: parseMonthKey(monthKey(d)) conserva año y mes", () => {
    const d = new Date(2025, 11, 31)
    const parsed = parseMonthKey(monthKey(d))
    expect(parsed.getFullYear()).toBe(2025)
    expect(parsed.getMonth()).toBe(11)
  })
})

describe("utcPrevMonthRange", () => {
  it("returns the previous calendar month", () => {
    const { from, to } = utcPrevMonthRange(new Date(2026, 5, 17)) // June -> May
    expect(from).toBe("2026-05-01T00:00:00.000Z")
    expect(to).toBe("2026-05-31T23:59:59.999Z")
  })

  it("rolls back across the year boundary (January -> previous December)", () => {
    const { from, to } = utcPrevMonthRange(new Date(2026, 0, 9)) // Jan 2026 -> Dec 2025
    expect(from).toBe("2025-12-01T00:00:00.000Z")
    expect(to).toBe("2025-12-31T23:59:59.999Z")
  })
})
