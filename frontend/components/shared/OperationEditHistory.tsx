"use client"

/**
 * OperationEditHistory — el "Historial de cambios" del detalle expandido de una venta, una compra o un gasto
 * (edicion-operaciones-con-dinero, tanda C, D14/D17). Cada edición queda en `audit_logs` en la misma transacción que la
 * corrige; acá se muestra quién la hizo, cuándo y un resumen (importe y fecha antes → después, libros que tocó, motivo).
 *
 * Carga DIFERIDA: no consulta nada hasta que el usuario lo abre (el listado puede tener decenas de filas expandibles).
 * Es un botón nativo con `aria-expanded`/`aria-controls` y una región con nombre: operable por teclado sin
 * trabajo extra. Sin ediciones, lo dice; no inventa un estado.
 */

import { useId, useState } from "react"
import { ChevronDown, History } from "lucide-react"
import { useOperationEditHistory } from "@/hooks/data/use-operation-edit"
import type { EditableDocumentKind, OperationEditEntry } from "@/lib/operation-edit-api"
import { ARGENTINA_TIMEZONE, argentinaToday } from "@/lib/date-range"
import { formatDate } from "@/lib/format"
import { summarizeEdit, type EditedDocument } from "@/lib/money-plan"
import { cn } from "@/lib/utils"

interface OperationEditHistoryProps {
  kind: EditableDocumentKind
  /** `operation_id` de la venta o la compra; id del gasto. */
  entityId: string | null | undefined
  document: EditedDocument
  /** Abierto desde el principio (las pruebas y los casos en que ya se sabe que hay cambios). */
  defaultOpen?: boolean
  className?: string
}

/** El instante de la edición, en día y hora argentinos (nunca el prefijo UTC de la cadena). */
function whenLabel(createdAt: string): string {
  const instant = new Date(createdAt)
  if (Number.isNaN(instant.getTime())) return "—"
  const time = instant.toLocaleTimeString("es-AR", {
    timeZone: ARGENTINA_TIMEZONE,
    hour: "2-digit",
    minute: "2-digit",
  })
  return `${formatDate(argentinaToday(instant))} ${time}`
}

function EntryRow({ entry, document }: { entry: OperationEditEntry; document: EditedDocument }) {
  return (
    <li className="space-y-0.5 border-l-2 border-border pl-3">
      <p className="text-xs text-muted-foreground">
        <span className="font-medium text-foreground">{entry.user_name ?? "Usuario desconocido"}</span>
        {" · "}
        <time dateTime={entry.created_at}>{whenLabel(entry.created_at)}</time>
      </p>
      <p className="text-sm text-foreground">{summarizeEdit(entry, document)}</p>
    </li>
  )
}

/** El cuerpo del historial: recién acá se consulta (el hook se monta cuando el usuario abre el historial). */
function HistoryBody({ kind, entityId, document }: { kind: EditableDocumentKind; entityId: string | null | undefined; document: EditedDocument }) {
  const history = useOperationEditHistory(kind, entityId, true)
  if (history.isLoading) {
    return <p role="status" className="text-xs text-muted-foreground">Cargando el historial…</p>
  }
  if (history.isError) {
    return (
      <div role="alert" className="flex items-center gap-2 text-xs text-destructive">
        <span>No se pudo cargar el historial.</span>
        <button type="button" onClick={() => void history.refetch()} className="underline underline-offset-2">
          Reintentar
        </button>
      </div>
    )
  }
  const entries = history.data ?? []
  if (entries.length === 0) {
    return <p className="text-xs text-muted-foreground">Esta operación no tiene cambios registrados.</p>
  }
  return (
    <ul className="space-y-2">
      {entries.map((entry) => (
        <EntryRow key={entry.id} entry={entry} document={document} />
      ))}
    </ul>
  )
}

export function OperationEditHistory({ kind, entityId, document, defaultOpen = false, className }: OperationEditHistoryProps) {
  const [open, setOpen] = useState(defaultOpen)
  const regionId = useId()

  return (
    <div className={cn("space-y-2", className)}>
      <button
        type="button"
        onClick={(e) => {
          // El detalle vive dentro de una fila clickeable que expande/colapsa.
          e.stopPropagation()
          setOpen((v) => !v)
        }}
        aria-expanded={open}
        aria-controls={regionId}
        className="flex items-center gap-1.5 rounded-sm text-xs font-medium text-muted-foreground hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring"
      >
        <History className="h-3.5 w-3.5" aria-hidden="true" />
        Historial de cambios
        <ChevronDown className={cn("h-3.5 w-3.5 transition-transform", open && "rotate-180")} aria-hidden="true" />
      </button>

      <div id={regionId} role="region" aria-label="Historial de cambios" hidden={!open} onClick={(e) => e.stopPropagation()}>
        {open && <HistoryBody kind={kind} entityId={entityId} document={document} />}
      </div>
    </div>
  )
}
