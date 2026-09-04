// Parámetros de ventana del módulo de estadísticas para las Edge Functions
// (runtime Deno) — estadisticas-ventas E3 (grupo 8 export, grupo 10 IA).
//
// Un solo lugar que resuelve "qué período pidió el cliente" para
// generate-export (product_ranking_csv) y ai-estadisticas: fecha de negocio
// "YYYY-MM-DD" validada como día calendario real, rango no invertido, y los
// MISMOS defaults que la pantalla /estadisticas (últimos 30 días, hoy
// incluido). "Hoy" es el día calendario ARGENTINO (`argentinaToday`), no el
// día UTC del runtime — en la franja 21:00–24:00 ART ya es mañana en UTC.
//
// El clamp de historial por plan NO vive acá: lo aplica el read-model
// (reporting_plan_window, D8) aunque el cliente pida más. Acá sólo se valida
// la forma del pedido antes de tocar la base.
//
// TS puro, sin dependencias de `jsr:`/`npm:` ni referencias a `Deno.*` a
// nivel de módulo — deployable a Deno y testeable desde vitest por ruta
// relativa (patrón de `_shared/ai-quota.ts` / `_shared/argentina-time.ts`).

import { argentinaDaysAgoIso, argentinaToday } from "./argentina-time.ts"

export type ParseResult<T> = { ok: true; value: T } | { ok: false; error: string }

const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

/** "YYYY-MM-DD" que además es un día calendario real (2026-02-30 no lo es). */
export function isIsoBusinessDate(value: unknown): value is string {
  if (typeof value !== "string" || !ISO_DATE_RE.test(value)) return false
  const [y, m, d] = value.split("-").map(Number)
  const probe = new Date(Date.UTC(y, m - 1, d))
  return probe.getUTCFullYear() === y && probe.getUTCMonth() === m - 1 && probe.getUTCDate() === d
}

export function isUuid(value: unknown): value is string {
  return typeof value === "string" && UUID_RE.test(value)
}

/** Día argentino `days` días antes del día argentino de `now`, como "YYYY-MM-DD". */
export function argentinaDaysAgoDate(days: number, now: Date): string {
  return argentinaDaysAgoIso(days, now).slice(0, 10)
}

export interface BusinessDateRange {
  start: string
  end: string
}

/**
 * Rango de fechas de negocio del body. Defaults = la pantalla: los últimos
 * `defaultDays` días con hoy (argentino) incluido. Rechaza fechas mal
 * formadas o inexistentes y el rango invertido.
 */
export function parseBusinessDateRange(
  body: Record<string, unknown>,
  now: Date,
  defaultDays = 30,
): ParseResult<BusinessDateRange> {
  const rawStart = body["start"]
  const rawEnd = body["end"]
  if (rawStart !== undefined && rawStart !== null && !isIsoBusinessDate(rawStart)) {
    return { ok: false, error: "start debe ser una fecha YYYY-MM-DD válida" }
  }
  if (rawEnd !== undefined && rawEnd !== null && !isIsoBusinessDate(rawEnd)) {
    return { ok: false, error: "end debe ser una fecha YYYY-MM-DD válida" }
  }
  const end = typeof rawEnd === "string" ? rawEnd : argentinaToday(now)
  const start = typeof rawStart === "string" ? rawStart : argentinaDaysAgoDate(defaultDays - 1, now)
  if (end < start) {
    return { ok: false, error: "El fin del rango es anterior al inicio" }
  }
  return { ok: true, value: { start, end } }
}

/** uuid opcional del body: ausente o null = sin filtro; cualquier otra cosa
 *  que no sea un uuid se rechaza. */
export function parseOptionalUuid(body: Record<string, unknown>, key: string): ParseResult<string | null> {
  const raw = body[key]
  if (raw === undefined || raw === null || raw === "") return { ok: true, value: null }
  if (!isUuid(raw)) return { ok: false, error: `${key} debe ser un uuid` }
  return { ok: true, value: raw }
}
