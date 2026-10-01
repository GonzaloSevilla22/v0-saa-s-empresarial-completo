/**
 * Argentina-anchored calendar-date range helpers for dashboard / KPI queries.
 *
 * WHY THIS EXISTS — app-timezone-argentina:
 *   Sales/expenses/purchases are written with a `date`-typed param, so Postgres
 *   stores them in the `timestamptz` column at MIDNIGHT UTC keyed to a calendar
 *   date (e.g. 2026-06-08 00:00:00+00). The app's business day is Argentina's
 *   calendar day (`America/Argentina/Mendoza`, UTC-3, sin DST desde 2009) —
 *   independent of BOTH the browser's local timezone AND the server's clock.
 *   Between 21:00 and 23:59:59 ART the UTC calendar date has already rolled to
 *   the next day; anchoring on UTC (or on the browser's arbitrary local zone)
 *   shifts "today" a day forward in that window — a sale entered at 22:00 ART
 *   used to get saved with tomorrow's date.
 *
 *   The fix: derive the Y/M/D via `Intl.DateTimeFormat` with an explicit
 *   `America/Argentina/Mendoza` timeZone (D1 — never a hardcoded -3 offset),
 *   then materialize the window boundaries at UTC midnight (how the rows are
 *   stored). `utcDayRange`/`utcMonthRange`/`utcPrevMonthRange`/`monthKey`/
 *   `parseMonthKey` keep their signatures and output shape (D2) — only the
 *   source of the Y/M/D changed, from the browser's local clock to
 *   `argentinaToday()`.
 */

const ARGENTINA_TIMEZONE = "America/Argentina/Mendoza"

export interface IsoRange {
  /** Inclusive lower bound, ISO 8601 (UTC). */
  from: string
  /** Inclusive upper bound, ISO 8601 (UTC). */
  to: string
}

interface ArgentinaDayParts {
  y: number
  /** 0-indexed, matches `Date#getMonth()`. */
  m: number
  day: number
}

/** Reads the Argentina calendar-day components of the instant `d`, via
 *  `Intl.DateTimeFormat` (D1) — never a hardcoded UTC-3 offset. Works from
 *  the absolute instant, so it is independent of the runtime's local TZ. */
function argentinaDayParts(d: Date): ArgentinaDayParts {
  const parts = new Intl.DateTimeFormat("en-CA", {
    timeZone: ARGENTINA_TIMEZONE,
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  }).formatToParts(d)
  const get = (type: string): number => Number(parts.find((p) => p.type === type)?.value ?? NaN)
  return { y: get("year"), m: get("month") - 1, day: get("day") }
}

/** Builds the UTC instant that reads back as (y, m, day) via
 *  `argentinaDayParts` — ART midnight of that calendar date (03:00 UTC, no
 *  DST). Used so values that round-trip through `parseMonthKey` →
 *  `monthKey`/`utcMonthRange` stay correct regardless of the runtime's local
 *  timezone (never built via the local `Date` constructor). */
function argentinaMidnightUtc(y: number, m: number, day: number): Date {
  return new Date(Date.UTC(y, m, day, 3, 0, 0, 0))
}

/** The Argentina calendar day ("YYYY-MM-DD") for the instant `d` — the single
 *  source of truth for "today" across the app (D1). */
export function argentinaToday(d: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: ARGENTINA_TIMEZONE }).format(d)
}

/** The Argentina calendar day ("YYYY-MM-DD") `days` days before the Argentina
 *  day of `d`. `days = 0` is equivalent to `argentinaToday(d)`. */
export function argentinaDaysAgo(days: number, d: Date = new Date()): string {
  const { y, m, day } = argentinaDayParts(d)
  return new Date(Date.UTC(y, m, day - days)).toISOString().slice(0, 10)
}

// ─── Tabla de casos canónica ────────────────────────────────────────────────
//
// Paridad con `supabase/functions/_shared/argentina-time.ts`, verificada por
// `frontend/__tests__/lib/argentina-time-parity.test.ts` — divergencia en
// cualquier caso = CI rojo (business-day-timezone, requirement "Paridad
// entre helpers de runtimes").

export interface ArgentinaDayCase {
  name: string
  /** Instante absoluto UTC (siempre con `Z`) — nunca ambiguo por huso. */
  instantIso: string
  /** Día calendario argentino esperado, "YYYY-MM-DD". */
  expectedDay: string
}

export const argentinaDayCases: ArgentinaDayCase[] = [
  { name: "20:59 ART — todavía el día D", instantIso: "2026-06-08T23:59:00.000Z", expectedDay: "2026-06-08" },
  { name: "21:00 ART — bug clásico: UTC ya es D+1, ART sigue en D", instantIso: "2026-06-09T00:00:00.000Z", expectedDay: "2026-06-08" },
  { name: "23:59 ART — todavía el día D", instantIso: "2026-06-09T02:59:00.000Z", expectedDay: "2026-06-08" },
  { name: "00:00 ART — ya es el día D", instantIso: "2026-06-08T03:00:00.000Z", expectedDay: "2026-06-08" },
  { name: "borde de mes (31→1): 21:00 ART del 31/may sigue en mayo", instantIso: "2026-06-01T00:00:00.000Z", expectedDay: "2026-05-31" },
  { name: "borde de mes (31→1): 00:00 ART del 1/jun ya es junio", instantIso: "2026-06-01T03:00:00.000Z", expectedDay: "2026-06-01" },
  { name: "borde de año: 22:00 ART del 31/dic sigue en el año viejo", instantIso: "2027-01-01T01:00:00.000Z", expectedDay: "2026-12-31" },
]

const startOfDayUtc = (y: number, m: number, d: number): string =>
  new Date(Date.UTC(y, m, d, 0, 0, 0, 0)).toISOString()

const endOfDayUtc = (y: number, m: number, d: number): string =>
  new Date(Date.UTC(y, m, d, 23, 59, 59, 999)).toISOString()

/** Calendar-day window [00:00:00.000Z .. 23:59:59.999Z] for the Argentina date of `d`. */
export function utcDayRange(d: Date = new Date()): IsoRange {
  const { y, m, day } = argentinaDayParts(d)
  return { from: startOfDayUtc(y, m, day), to: endOfDayUtc(y, m, day) }
}

/** Calendar-month window for the month containing the Argentina date of `d`. */
export function utcMonthRange(d: Date = new Date()): IsoRange {
  const { y, m } = argentinaDayParts(d)
  // Day 0 of the next month = last day of this month. Date.UTC normalizes overflow.
  return { from: startOfDayUtc(y, m, 1), to: endOfDayUtc(y, m + 1, 0) }
}

/** Calendar-month window for the month BEFORE the one containing `d` (month-over-month deltas). */
export function utcPrevMonthRange(d: Date = new Date()): IsoRange {
  const { y, m } = argentinaDayParts(d)
  // Date.UTC normalizes month underflow (m - 1 < 0 rolls back the year).
  return { from: startOfDayUtc(y, m - 1, 1), to: endOfDayUtc(y, m, 0) }
}

/** "YYYY-MM" key for the Argentina month of `d` — used by the dashboard ?period= param. */
export function monthKey(d: Date = new Date()): string {
  const { y, m } = argentinaDayParts(d)
  return `${y}-${String(m + 1).padStart(2, "0")}`
}

/** Parse a "YYYY-MM" key to the 1st of that month. The returned `Date` is an
 *  opaque value carrier meant to be read back via `monthKey`/`utcMonthRange`/
 *  `utcPrevMonthRange` (all ART-based) — it is anchored at ART midnight
 *  (`argentinaMidnightUtc`), not built via the local `Date` constructor, so
 *  it round-trips correctly regardless of the runtime's local timezone.
 *  Invalid/null input falls back to the current Argentina month. */
export function parseMonthKey(key: string | null | undefined): Date {
  if (key && /^\d{4}-(0[1-9]|1[0-2])$/.test(key)) {
    const [y, m] = key.split("-").map(Number)
    return argentinaMidnightUtc(y, m - 1, 1)
  }
  const { y, m } = argentinaDayParts(new Date())
  return argentinaMidnightUtc(y, m, 1)
}
