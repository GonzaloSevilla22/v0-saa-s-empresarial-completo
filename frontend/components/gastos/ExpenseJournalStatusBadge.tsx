"use client"

/**
 * Estado contable del gasto — asiento-contable-gastos (D9).
 *
 * Tres estados, derivados en el SERVIDOR (`ExpenseOut.hasJournalEntry` /
 * `journalPending`, calculados en SQL en `expense_repository.py`) y nunca
 * reconstruidos en el cliente con una consulta por fila:
 *
 *   asentado    — hay un asiento vigente y ningún evento sin procesar; el
 *                 badge ENLAZA al libro diario filtrado por este gasto
 *                 (`source_doc_ref`).
 *   pendiente   — hay evento emitido, el relay todavía no lo procesó. Tono
 *                 NEUTRO/warning — "en unos minutos", nunca un error.
 *   sin_asiento — gasto anterior a la puesta en marcha del asiento contable.
 *                 Estado legítimo, tono neutro, nunca un error.
 *
 * `journalPending` PREVALECE sobre `hasJournalEntry` (F2, revisor adversarial
 * ronda de nits, opción (a)): un gasto recién EDITADO puede tener, a la vez,
 * el asiento anterior todavía `posted` (el relay no lo revirtió) y el evento
 * `ExpenseAdjusted` sin despachar — ese gasto se está por mover, así que el
 * badge dice "Pendiente" en vez de "Asentado" para no mostrar como firme un
 * estado que está a punto de cambiar. El enlace al libro diario se conserva
 * igual mientras `hasJournalEntry` sea true: SIGUE existiendo un asiento
 * vigente para mostrar (el anterior a la edición), sólo que no es definitivo.
 *
 * Molde: `components/clientes/ClientActivityBadge.tsx` — cva + tokens
 * semánticos, el estado SIEMPRE lleva texto visible (nunca sólo color).
 */

import Link from "next/link"
import { cva } from "class-variance-authority"
import { cn } from "@/lib/utils"

export type ExpenseJournalStatus = "asentado" | "pendiente" | "sin_asiento"

export function deriveExpenseJournalStatus(row: {
  hasJournalEntry?: boolean
  journalPending?: boolean
}): ExpenseJournalStatus {
  // F2: journalPending gana sobre hasJournalEntry — ver el comentario del
  // encabezado. No invertir este orden sin revisar el render de más abajo
  // (showsLink), que depende de que "pendiente" también pueda enlazar.
  if (row.journalPending) return "pendiente"
  if (row.hasJournalEntry) return "asentado"
  return "sin_asiento"
}

const journalStatusBadgeVariants = cva(
  "inline-flex items-center rounded-full border px-2.5 py-0.5 text-[10px] font-semibold whitespace-nowrap",
  {
    variants: {
      status: {
        asentado:    "border-transparent bg-success/15 text-success",
        pendiente:   "border-transparent bg-warning/15 text-warning",
        sin_asiento: "border-border bg-transparent text-muted-foreground",
      },
    },
  },
)

export const EXPENSE_JOURNAL_STATUS_LABEL: Record<ExpenseJournalStatus, string> = {
  asentado:    "Asentado",
  pendiente:   "Pendiente",
  sin_asiento: "Sin asiento",
}

const STATUS_TITLE: Record<ExpenseJournalStatus, string> = {
  asentado:    "Ver el asiento en el libro diario",
  // D9: se comunica como espera normal, nunca como error — el posteo es
  // asincrónico por diseño (el relay corre cada minuto).
  pendiente:   "El asiento se registra en unos minutos",
  // D9: condición legítima de los gastos históricos, no un fallo.
  sin_asiento: "Gasto anterior a la puesta en marcha del asiento contable",
}

export interface ExpenseJournalStatusBadgeProps {
  expenseId: string
  hasJournalEntry?: boolean
  journalPending?: boolean
  className?: string
}

export function ExpenseJournalStatusBadge({
  expenseId,
  hasJournalEntry,
  journalPending,
  className,
}: ExpenseJournalStatusBadgeProps) {
  const status = deriveExpenseJournalStatus({ hasJournalEntry, journalPending })
  const label = EXPENSE_JOURNAL_STATUS_LABEL[status]
  const title = STATUS_TITLE[status]

  // F2: "pendiente" con hasJournalEntry=true significa que el asiento
  // anterior a la edición sigue vigente (todavía no lo revirtió el relay) —
  // el enlace al libro diario se conserva, sólo cambia el label/tono.
  const showsLink = status === "asentado" || (status === "pendiente" && hasJournalEntry)

  if (showsLink) {
    return (
      <Link
        href={`/reportes/libro-diario?source_doc_type=Expense&source_doc_ref=${expenseId}`}
        title={title}
        data-testid="expense-journal-status"
        className={cn(
          journalStatusBadgeVariants({ status }),
          "hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
          className,
        )}
      >
        {label}
      </Link>
    )
  }

  return (
    <span
      title={title}
      data-testid="expense-journal-status"
      className={cn(journalStatusBadgeVariants({ status }), className)}
    >
      {label}
    </span>
  )
}
