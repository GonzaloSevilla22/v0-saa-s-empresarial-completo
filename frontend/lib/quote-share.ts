/**
 * presupuestos-modulo (D9) — el texto corto que acompaña al PDF del
 * presupuesto cuando se manda por WhatsApp. Función pura.
 *
 * "Hola Ana, te envío el presupuesto P-00000012 por $ 12.345, válido hasta el
 * 14/10/2026. Kiosco Lola". Sin nombre: sin saludo personalizado; sin validez
 * o sin negocio, la cláusula correspondiente se omite entera.
 */
import { formatMoney } from "@/lib/format"

export interface QuoteShareTextInput {
  clientName?: string | null
  numberLabel: string
  total: number
  /** Fecha ISO `YYYY-MM-DD` (fecha de negocio, no instante). */
  validUntil?: string | null
  businessName?: string | null
}

/** `2026-10-14` -> `14/10/2026`, desde el texto: pasar por `Date` correría el día. */
function formatIsoDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-")
  return `${d}/${m}/${y}`
}

export function buildQuoteShareText({
  clientName,
  numberLabel,
  total,
  validUntil,
  businessName,
}: QuoteShareTextInput): string {
  const name = clientName?.trim()
  const greeting = name ? `Hola ${name},` : "Hola,"
  const validity = validUntil ? `, válido hasta el ${formatIsoDate(validUntil)}` : ""
  const sentence = `${greeting} te envío el presupuesto ${numberLabel} por ${formatMoney(total)}${validity}.`
  const business = businessName?.trim()
  return business ? `${sentence} ${business}` : sentence
}
