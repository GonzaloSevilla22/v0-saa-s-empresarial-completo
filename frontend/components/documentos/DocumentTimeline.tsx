/**
 * v3-document-status-history (task 6.2, D8) — línea de tiempo del documento.
 *
 * Server Component: lee document_status_history server-side (RLS solo-SELECT
 * por account_id — RN-A3) ordenado por occurred_at y renderiza la línea de
 * tiempo. Documentos creados antes del change no tienen historial (Non-Goal:
 * sin backfill) → estado vacío.
 */
import { History } from "lucide-react"

import {
  describeTransition,
  formatTimelineActor,
  sortTimelineEntries,
} from "@/lib/document-timeline-utils"
import { createClient } from "@/lib/supabase/server"
import type { DocumentStatusHistoryEntry, DocumentTypeSlug } from "@/lib/types"

interface DocumentTimelineProps {
  documentType: DocumentTypeSlug
  documentId: string
  /** Título de la sección; por defecto "Historial de estados". */
  title?: string
}

/** Fila cruda de Supabase (snake_case) — mapeada al tipo de dominio. */
interface DocumentStatusHistoryRow {
  id: string
  account_id: string
  document_type: DocumentTypeSlug
  document_id: string
  from_status: string | null
  to_status: string
  performed_by: string
  reason: string | null
  occurred_at: string
}

function mapRow(row: DocumentStatusHistoryRow): DocumentStatusHistoryEntry {
  return {
    id: row.id,
    accountId: row.account_id,
    documentType: row.document_type,
    documentId: row.document_id,
    fromStatus: row.from_status,
    toStatus: row.to_status,
    performedBy: row.performed_by,
    reason: row.reason,
    occurredAt: row.occurred_at,
  }
}

export async function DocumentTimeline({
  documentType,
  documentId,
  title = "Historial de estados",
}: DocumentTimelineProps) {
  const supabase = createClient()

  const { data, error } = await supabase
    .from("document_status_history")
    .select(
      "id, account_id, document_type, document_id, from_status, to_status, performed_by, reason, occurred_at"
    )
    .eq("document_type", documentType)
    .eq("document_id", documentId)
    .order("occurred_at", { ascending: true })

  const entries = sortTimelineEntries(
    ((data ?? []) as DocumentStatusHistoryRow[]).map(mapRow)
  )

  return (
    <section className="rounded-lg border border-border bg-card p-4">
      <h2 className="flex items-center gap-2 text-sm font-semibold text-foreground">
        <History className="h-4 w-4 text-muted-foreground" />
        {title}
      </h2>

      {error && (
        <p className="mt-3 text-xs text-red-500">
          No se pudo cargar el historial de estados.
        </p>
      )}

      {!error && entries.length === 0 && (
        <p className="mt-3 text-xs text-muted-foreground">
          Sin historial de estados registrado
        </p>
      )}

      {!error && entries.length > 0 && (
        <ol className="mt-3 flex flex-col gap-0 border-l border-border pl-4">
          {entries.map((entry) => {
            const occurredAt = new Date(entry.occurredAt)
            return (
              <li key={entry.id} className="relative pb-4 last:pb-0">
                <span
                  aria-hidden
                  className="absolute -left-[21px] top-1.5 h-2 w-2 rounded-full bg-primary"
                />
                <p className="text-sm font-medium text-foreground">
                  {describeTransition(entry)}
                </p>
                <p className="text-xs text-muted-foreground">
                  {occurredAt.toLocaleString("es-AR", {
                    day: "2-digit",
                    month: "short",
                    year: "numeric",
                    hour: "2-digit",
                    minute: "2-digit",
                  })}
                  {" · "}
                  {formatTimelineActor(entry.performedBy)}
                </p>
                {entry.reason && (
                  <p className="mt-0.5 text-xs italic text-muted-foreground">
                    Motivo: {entry.reason}
                  </p>
                )}
              </li>
            )
          })}
        </ol>
      )}
    </section>
  )
}
