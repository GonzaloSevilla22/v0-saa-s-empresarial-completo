/**
 * Lógica de variación y formato del Bloque Resumen KPI (spec ALIADATA v1.1 §5).
 *
 * Polaridad: para Ganancia/Margen/Ticket subir es BUENO (`up_good`); para
 * Costo por Venta y Stock sin Rotación subir es MALO (`up_bad`). El color del
 * badge depende de la dirección de la variación Y la polaridad del KPI.
 */

export type KpiPolarity = "up_good" | "up_bad"
export type KpiBadgeTone = "green" | "red" | "yellow"

/** Umbral bajo el cual la variación se considera "sin cambio significativo". */
export const SIGNIFICANT_DELTA_PCT = 5

/**
 * % de variación contra el período anterior. `null` cuando no hay baseline
 * (prev 0/null) o no hay dato actual — el badge cae a amarillo "—".
 */
export function kpiDeltaPct(
  curr: number | null | undefined,
  prev: number | null | undefined,
): number | null {
  if (curr == null || prev == null || prev === 0) return null
  return ((curr - prev) / Math.abs(prev)) * 100
}

/** Color del badge según variación y polaridad (verde/rojo/amarillo del spec §5). */
export function kpiBadgeTone(deltaPct: number | null, polarity: KpiPolarity): KpiBadgeTone {
  if (deltaPct === null || Math.abs(deltaPct) < SIGNIFICANT_DELTA_PCT) return "yellow"
  const wentUp = deltaPct > 0
  const favorable = polarity === "up_good" ? wentUp : !wentUp
  return favorable ? "green" : "red"
}

/** "▲ +12%" / "▼ -8%" / "—" (redondeado a entero). */
export function formatKpiDelta(deltaPct: number | null): string {
  if (deltaPct === null) return "—"
  const rounded = Math.round(deltaPct)
  const arrow = rounded >= 0 ? "▲" : "▼"
  const sign = rounded >= 0 ? "+" : ""
  return `${arrow} ${sign}${rounded}%`
}

/** "$184.200" estilo es-AR sin decimales; "—" sin dato; "-$1.500" en negativo. */
export function formatKpiCurrency(value: number | null | undefined): string {
  if (value == null) return "—"
  const rounded = Math.round(value)
  const abs = Math.abs(rounded)
  // Separador de miles con punto, determinístico (independiente del ICU del runtime).
  const grouped = abs.toString().replace(/\B(?=(\d{3})+(?!\d))/g, ".")
  return `${rounded < 0 ? "-" : ""}$${grouped}`
}

// ─── Margen por Canal (Fase B) ────────────────────────────────────────────────

/** Entrada de rpc_dashboard_channel_margin.channels (ordenada por margen desc). */
export interface ChannelMarginEntry {
  canal: string
  revenue: number
  margin_pct: number | null
}

/** Canales sugeridos en el form de venta (valor → etiqueta completa). */
export const SALE_CHANNELS: ReadonlyArray<{ value: string; label: string }> = [
  { value: "instagram", label: "Instagram" },
  { value: "mercadolibre", label: "MercadoLibre" },
  { value: "whatsapp", label: "WhatsApp" },
  { value: "local", label: "Local" },
  { value: "otro", label: "Otro" },
]

const CHANNEL_SHORT: Record<string, string> = {
  instagram: "IG",
  mercadolibre: "ML",
  whatsapp: "WA",
  sin_canal: "S/C",
}

/** Etiqueta corta del canal para la tarjeta ("IG", "ML"); desconocidos capitalizados. */
export function channelLabel(canal: string): string {
  return CHANNEL_SHORT[canal] ?? canal.charAt(0).toUpperCase() + canal.slice(1)
}

/** "IG 34% / ML 18%" con los 2 mejores canales (spec §3); "—" sin datos. */
export function formatChannelMargin(
  channels: ChannelMarginEntry[] | null | undefined,
): string {
  if (!channels || channels.length === 0) return "—"
  return channels
    .slice(0, 2)
    .map(c => `${channelLabel(c.canal)} ${Math.round(c.margin_pct ?? 0)}%`)
    .join(" / ")
}
