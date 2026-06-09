/**
 * UTC calendar-date range helpers for dashboard / KPI queries.
 *
 * WHY THIS EXISTS — the "$0 today" bug:
 *   Sales/expenses/purchases are written with a `date`-typed param, so Postgres
 *   stores them in the `timestamptz` column at MIDNIGHT UTC keyed to a calendar
 *   date (e.g. 2026-06-08 00:00:00+00). If the dashboard builds its window from
 *   the browser's LOCAL midnight (Argentina = UTC-3 → 03:00Z), every row lands in
 *   the previous day's bucket and "today" reads $0.
 *
 *   The fix: take the user's LOCAL calendar date (what "today"/"this month" means
 *   to them) and materialize the window at UTC midnight (how the rows are stored).
 *   So we read the LOCAL Y/M/D via getFullYear/getMonth/getDate, then build the
 *   boundaries with Date.UTC.
 */

export interface IsoRange {
  /** Inclusive lower bound, ISO 8601 (UTC). */
  from: string
  /** Inclusive upper bound, ISO 8601 (UTC). */
  to: string
}

const startOfDayUtc = (y: number, m: number, d: number): string =>
  new Date(Date.UTC(y, m, d, 0, 0, 0, 0)).toISOString()

const endOfDayUtc = (y: number, m: number, d: number): string =>
  new Date(Date.UTC(y, m, d, 23, 59, 59, 999)).toISOString()

/** Calendar-day window [00:00:00.000Z .. 23:59:59.999Z] for the local date of `d`. */
export function utcDayRange(d: Date = new Date()): IsoRange {
  const y = d.getFullYear()
  const m = d.getMonth()
  const day = d.getDate()
  return { from: startOfDayUtc(y, m, day), to: endOfDayUtc(y, m, day) }
}

/** Calendar-month window for the month containing the local date of `d`. */
export function utcMonthRange(d: Date = new Date()): IsoRange {
  const y = d.getFullYear()
  const m = d.getMonth()
  // Day 0 of the next month = last day of this month. Date.UTC normalizes overflow.
  return { from: startOfDayUtc(y, m, 1), to: endOfDayUtc(y, m + 1, 0) }
}

/** Calendar-month window for the month BEFORE the one containing `d` (month-over-month deltas). */
export function utcPrevMonthRange(d: Date = new Date()): IsoRange {
  const y = d.getFullYear()
  const m = d.getMonth()
  // Date.UTC normalizes month underflow (m - 1 < 0 rolls back the year).
  return { from: startOfDayUtc(y, m - 1, 1), to: endOfDayUtc(y, m, 0) }
}

/** "YYYY-MM" key for the local month of `d` — used by the dashboard ?period= param. */
export function monthKey(d: Date = new Date()): string {
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`
}

/** Parse a "YYYY-MM" key to the 1st of that month (local). Invalid/null falls back to the current month. */
export function parseMonthKey(key: string | null | undefined): Date {
  if (key && /^\d{4}-(0[1-9]|1[0-2])$/.test(key)) {
    const [y, m] = key.split("-").map(Number)
    return new Date(y, m - 1, 1)
  }
  const now = new Date()
  return new Date(now.getFullYear(), now.getMonth(), 1)
}
