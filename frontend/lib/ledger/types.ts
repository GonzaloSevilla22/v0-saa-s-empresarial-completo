/**
 * ledger-movement-history (D1) — tipos compartidos por LedgerMovementsPanel.
 *
 * Un solo componente, dos configuraciones de libro (cash | bank). Este
 * archivo define el "descriptor de libro" que concentra las diferencias
 * entre ambos en un objeto de configuración — la regla PO de reutilización
 * antes que repetición, evitando el patrón `if (book === 'cash')` disperso
 * por todo el componente (design.md, Risks).
 */
import { HelpCircle, type LucideIcon } from "lucide-react"
import type { ReactNode } from "react"
import type { Page } from "@/lib/types"

/** Tono semántico del badge/monto — mapea a los tokens de tokens-contraste-aa
 * (bg-{role}/15 text-{role} border-{role}/25), nunca colores literales. */
export type LedgerTone = "success" | "destructive" | "warning" | "primary" | "muted"

export interface LedgerMovementMeta {
  label: string
  icon: LucideIcon
  tone: LedgerTone
  /** Clave de familia para las píldoras de filtro (ver `families`). */
  family: string
}

/** Fallback neutro para un tipo desconocido — la fila no debe romper (task 7.8). */
export const UNKNOWN_MOVEMENT_META: LedgerMovementMeta = {
  label: "Otro",
  icon: HelpCircle,
  tone: "muted",
  family: "other",
}

export interface LedgerFamily {
  key: string
  label: string
  types: string[]
}

/** Fila genérica que consume el panel — cash y bank la extienden con lo suyo. */
export interface LedgerRowBase {
  id: string
  amount: number
  movementType: string
  description: string | null
  balanceAfter: number
  createdAt: string
}

export interface LedgerFetchParams {
  page: number
  size: number
  types?: string[]
  q?: string
  from?: string
  to?: string
  /** Filtro extra específico del libro (p. ej. reconciliationStatus en banco). */
  extra?: Record<string, string>
}

export interface LedgerBookConfig<TRow extends LedgerRowBase> {
  book: "cash" | "bank"
  meta: Record<string, LedgerMovementMeta>
  families: LedgerFamily[]
  /** Header + celda de la columna extra del libro (Sesión en caja, Conciliación en banco). */
  extraColumn: {
    header: string
    render: (row: TRow) => ReactNode
  }
  /** Filtro extra opcional del libro (p. ej. estado de conciliación en banco). */
  extraFilter?: {
    key: string
    label: string
    options: { value: string; label: string }[]
  }
  fetchPage: (params: LedgerFetchParams) => Promise<Page<TRow>>
  csvName: string
  csvRow: (row: TRow) => (string | number)[]
  csvHeader: string[]
}
