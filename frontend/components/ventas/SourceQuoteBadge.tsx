"use client"

/**
 * SourceQuoteBadge — "Desde presupuesto P-00000012", con enlace al presupuesto
 * (presupuestos-modulo D10, task 6.10).
 *
 * El número se formatea con `formatInternalDocumentNumber` (la única definición
 * de la etiqueta). Un presupuesto anterior al módulo no tiene número: el badge
 * enlaza igual y no inventa uno.
 *
 * Vive dentro de una fila clickeable (expande/colapsa el detalle): el enlace
 * frena el evento para que seguirlo no abra ni cierre la fila.
 */

import Link from "next/link"
import { FileText } from "lucide-react"
import { formatInternalDocumentNumber } from "@/lib/internal-document-number"
import { cn } from "@/lib/utils"

interface SourceQuoteBadgeProps {
  quoteId: string
  quoteNumber: number | null
  className?: string
}

export function SourceQuoteBadge({ quoteId, quoteNumber, className }: SourceQuoteBadgeProps) {
  const label =
    quoteNumber === null ? "Desde presupuesto" : `Desde presupuesto ${formatInternalDocumentNumber("quote", quoteNumber)}`

  return (
    <Link
      href={`/presupuestos/${quoteId}`}
      onClick={(e) => e.stopPropagation()}
      onKeyDown={(e) => e.stopPropagation()}
      title={label}
      className={cn(
        // `min-w-0` + `overflow-hidden` + etiqueta con `truncate`: dentro de una
        // columna angosta el badge se achica en vez de ensanchar la fila (el
        // desborde horizontal fue la clase de bug que cerró `qa-integral-modulos`).
        "inline-flex w-fit min-w-0 max-w-full items-center gap-1 overflow-hidden rounded-md border border-primary/30 bg-primary/10 px-1.5 py-0.5",
        "text-[10px] font-semibold text-primary hover:underline focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring",
        className,
      )}
    >
      <FileText className="h-2.5 w-2.5 shrink-0" aria-hidden="true" />
      <span className="truncate">{label}</span>
    </Link>
  )
}
