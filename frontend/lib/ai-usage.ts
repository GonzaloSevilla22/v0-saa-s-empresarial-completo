/**
 * Reglas de cuota de IA compartidas entre pantallas.
 *
 * v31-ia-ratelimit-budget (D8): los contadores de IA se reinician con el cron
 * `reset-ai-counters` a las 00:00 UTC del día 1 de cada mes. `nextAiResetDate` es la
 * MISMA regla que usa `rpc_reserve_ai_usage` para devolver `reset_at`.
 */

/**
 * Próxima renovación de los contadores: día 1 del mes siguiente a las 00:00 UTC. En el
 * instante exacto del reset el cron ya corrió, por eso apunta al mes que sigue.
 */
export function nextAiResetDate(now: Date): Date {
  return new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() + 1, 1))
}

const RESET_FORMAT = new Intl.DateTimeFormat("es-AR", { day: "numeric", month: "long", timeZone: "UTC" })

/** «1 de diciembre» — fecha de renovación en español, fija en UTC (no se corre por la zona del navegador). */
export function formatAiResetDate(date: Date): string {
  return RESET_FORMAT.format(date)
}
