// Aritmética canónica de "día de negocio argentino" para las Edge Functions
// (runtime Deno) — app-timezone-argentina, D1/D3.
//
// Gemelo frontend: `frontend/lib/date-range.ts` (mismo cálculo de Y/M/D vía
// `Intl.DateTimeFormat` con `timeZone: 'America/Argentina/Mendoza'`, nunca un
// offset -3 fijo). Ambos exponen `argentinaToday()` con idéntica semántica y
// están atados por un test de paridad:
// `frontend/__tests__/lib/argentina-time-parity.test.ts` — divergencia en
// cualquier caso de la tabla compartida (bordes de día/mes/año en la franja
// 21:00–24:00 ART) pone ese test en rojo.
//
// TS puro, sin dependencias de `jsr:`/`npm:` ni referencias a `Deno.*` a
// nivel de módulo — es lo que lo hace deployable a Deno (`supabase functions
// deploy`) y a la vez testeable desde vitest importándolo por ruta relativa
// (patrón ya usado por `_shared/reporting-canon.ts`).

const ARGENTINA_TIMEZONE = "America/Argentina/Mendoza"

interface ArgentinaDayParts {
  y: number
  /** 0-indexed, matches `Date#getMonth()`. */
  m: number
  day: number
}

/** Lee los componentes de día calendario argentino del instante `d`, vía
 *  `Intl.DateTimeFormat` (D1) — nunca un offset -3 fijo. Depende solo del
 *  instante absoluto, no del huso local del runtime. */
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

/** El día calendario argentino ("YYYY-MM-DD") del instante `d`. */
export function argentinaToday(d: Date = new Date()): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: ARGENTINA_TIMEZONE }).format(d)
}

/** Instante ISO (medianoche UTC) del día argentino `days` días antes del día
 *  argentino de `d`. Usado por los fallbacks rolling de las Edge Functions IA
 *  cuando el caller no manda `dateFrom`/`dateTo` explícito — ancla al día
 *  argentino D, no al día UTC (que puede ya ser D+1 en la franja 21:00–24:00 ART). */
export function argentinaDaysAgoIso(days: number, d: Date = new Date()): string {
  const { y, m, day } = argentinaDayParts(d)
  return new Date(Date.UTC(y, m, day - days, 0, 0, 0, 0)).toISOString()
}

/** Instante ISO (medianoche UTC) del día argentino `months` meses calendario
 *  antes del de `d`, mismo día del mes (fallback "monthly" de ai-resumen). */
export function argentinaMonthsAgoIso(months: number, d: Date = new Date()): string {
  const { y, m, day } = argentinaDayParts(d)
  return new Date(Date.UTC(y, m - months, day, 0, 0, 0, 0)).toISOString()
}

/** Instante ISO (medianoche UTC) del primer día del mes calendario argentino
 *  que contiene `d` (fallback "current month" de ai-simulador). */
export function argentinaFirstDayOfMonthIso(d: Date = new Date()): string {
  const { y, m } = argentinaDayParts(d)
  return new Date(Date.UTC(y, m, 1, 0, 0, 0, 0)).toISOString()
}
