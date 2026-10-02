/**
 * presupuestos-modulo — rótulos y estado efectivo del presupuesto, en la capa
 * canónica para que el badge, las pestañas del listado y el detalle hablen del
 * mismo estado con las mismas palabras.
 */
import type { QuoteStatus } from "@/lib/quote-types"

export const QUOTE_STATUS_LABELS: Record<QuoteStatus, string> = {
  draft: "Borrador",
  sent: "Enviado",
  accepted: "Aceptado",
  expired: "Vencido",
  rejected: "Rechazado",
}

/**
 * El estado que se le muestra al usuario: un `draft`/`sent` con la validez
 * pasada (`is_expired`, derivado por el servidor con el día ART) es "vencido"
 * aunque el barrido diario todavía no lo haya marcado.
 */
export function effectiveQuoteStatus(status: QuoteStatus, isExpired?: boolean): QuoteStatus {
  if (isExpired && (status === "draft" || status === "sent")) return "expired"
  return status
}
