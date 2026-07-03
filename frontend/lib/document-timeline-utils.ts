/**
 * v3-document-status-history — lógica presentacional pura del DocumentTimeline.
 *
 * Separada del Server Component para ser testeable con vitest sin mockear
 * next/headers ni Supabase. Labels en es-AR por tipo de documento; el actor
 * se muestra como uuid abreviado ("la UI resuelve el nombre al renderizar" —
 * decisión de checkpoint: performed_by se guarda como uuid) y el uuid cero
 * representa al sistema (relay CAE).
 */
import type { DocumentStatusHistoryEntry, DocumentTypeSlug } from "@/lib/types"

export const SYSTEM_ACTOR_UUID = "00000000-0000-0000-0000-000000000000"

const STATUS_LABELS: Record<DocumentTypeSlug, Record<string, string>> = {
  quote: {
    draft: "Borrador",
    sent: "Enviado",
    accepted: "Aceptado",
    expired: "Vencido",
    rejected: "Rechazado",
  },
  sales_order: {
    draft: "Borrador",
    confirmed: "Confirmada",
    canceled: "Cancelada",
  },
  fiscal_document: {
    pending_cae: "CAE pendiente",
    authorized: "Autorizado",
    rejected: "Rechazado",
  },
  cash_session: {
    open: "Abierta",
    closed: "Cerrada",
  },
  reconciliation_session: {
    open: "Abierta",
    closed: "Cerrada",
  },
  stock_transfer: {
    completed: "Completada",
  },
}

/** Label es-AR del estado; devuelve el estado crudo si no hay traducción. */
export function getStatusLabel(documentType: DocumentTypeSlug, status: string): string {
  return STATUS_LABELS[documentType]?.[status] ?? status
}

/** "Sistema" para el uuid cero (relay CAE); uuid abreviado para usuarios. */
export function formatTimelineActor(performedBy: string): string {
  if (performedBy === SYSTEM_ACTOR_UUID) {
    return "Sistema"
  }
  return `${performedBy.slice(0, 8)}…`
}

/** Descripción de la entrada: creación (RN-A2) o transición entre estados. */
export function describeTransition(entry: DocumentStatusHistoryEntry): string {
  const toLabel = getStatusLabel(entry.documentType, entry.toStatus)
  if (entry.fromStatus === null) {
    return `Creado como ${toLabel}`
  }
  const fromLabel = getStatusLabel(entry.documentType, entry.fromStatus)
  return `${fromLabel} → ${toLabel}`
}

/** Orden ascendente por occurredAt (estable, no muta el input). */
export function sortTimelineEntries(
  entries: DocumentStatusHistoryEntry[]
): DocumentStatusHistoryEntry[] {
  return [...entries].sort(
    (a, b) => new Date(a.occurredAt).getTime() - new Date(b.occurredAt).getTime()
  )
}
