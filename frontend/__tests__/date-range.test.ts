import { describe, it, expect } from "vitest"
import { utcDayRange, utcMonthRange, utcPrevMonthRange } from "@/lib/date-range"

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
