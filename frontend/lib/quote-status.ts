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

/** Pestañas del listado: el filtro de estado lo resuelve el SERVIDOR (estado efectivo). */
export const QUOTE_LIST_TABS: ReadonlyArray<{ value: QuoteStatus | "all"; label: string; noun: string }> = [
  { value: "all", label: "Todos", noun: "" },
  { value: "draft", label: "Borradores", noun: "borradores" },
  { value: "sent", label: "Enviados", noun: "enviados" },
  { value: "accepted", label: "Aceptados", noun: "aceptados" },
  { value: "expired", label: "Vencidos", noun: "vencidos" },
  { value: "rejected", label: "Rechazados", noun: "rechazados" },
]
