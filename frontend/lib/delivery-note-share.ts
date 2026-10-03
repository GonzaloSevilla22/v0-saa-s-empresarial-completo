/**
 * remitos-venta (D11) — el texto corto que acompaña al PDF del remito cuando se
 * manda por WhatsApp. Función pura.
 *
 * "Hola Ana, te envío el remito R-00000012 de la mercadería entregada el
 * 02/10/2026. Kiosco Lola". Sin nombre: sin saludo personalizado; sin negocio,
 * la cola se omite. `onShared` no cambia el estado: el remito no tiene "enviado".
 */

export interface DeliveryNoteShareTextInput {
  clientName?: string | null
  /** `R-00000012`; `null` en una fila sin numerar: se omite en vez de inventarlo. */
  numberLabel: string | null
  /** Fecha ISO `YYYY-MM-DD` (fecha de negocio, no instante). */
  issuedOn: string
  businessName?: string | null
}

/** `2026-10-02` -> `02/10/2026`, desde el texto: pasar por `Date` correría el día. */
function formatIsoDate(iso: string): string {
  const [y, m, d] = iso.slice(0, 10).split("-")
  return `${d}/${m}/${y}`
}

export function buildDeliveryNoteShareText({
  clientName,
  numberLabel,
  issuedOn,
  businessName,
}: DeliveryNoteShareTextInput): string {
  const name = clientName?.trim()
  const greeting = name ? `Hola ${name},` : "Hola,"
  const remito = numberLabel ? `el remito ${numberLabel}` : "el remito"
  const sentence = `${greeting} te envío ${remito} de la mercadería entregada el ${formatIsoDate(issuedOn)}.`
  const business = businessName?.trim()
  return business ? `${sentence} ${business}` : sentence
}
