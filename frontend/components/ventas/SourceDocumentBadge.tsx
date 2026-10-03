"use client"

/**
 * SourceDocumentBadge — "Desde presupuesto P-00000012" / "Desde remito R-00000007",
 * con enlace al documento de origen de una venta (presupuestos-modulo D10 y
 * remitos-venta D13, task 7.6).
 *
 * Un solo componente para los dos orígenes (sin un badge gemelo por documento):
 * el tipo decide la palabra, el número y el destino del enlace. El número se
 * formatea con la definición única de `lib/internal-document-number`
 * (`formatInternalDocumentNumber` / `formatDeliveryNoteNumber`); un documento
 * anterior al módulo no tiene número: el badge enlaza igual y no inventa uno.
 *
 * Vive dentro de una fila clickeable (expande/colapsa el detalle): el enlace
 * frena el evento para que seguirlo no abra ni cierre la fila.
 */

import Link from "next/link"
import { FileText, Truck } from "lucide-react"
import { formatDeliveryNoteNumber, formatInternalDocumentNumber } from "@/lib/internal-document-number"
import { cn } from "@/lib/utils"

export type SourceDocumentKind = "quote" | "delivery_note"

interface SourceDocumentBadgeProps {
  kind: SourceDocumentKind
  documentId: string
  documentNumber: number | null
  className?: string
}

const KIND_META: Record<
  SourceDocumentKind,
  { word: string; href: (id: string) => string; format: (n: number) => string | null; Icon: typeof FileText }
> = {
  quote: {
    word: "presupuesto",
    href: (id) => `/presupuestos/${id}`,
    format: (n) => formatInternalDocumentNumber("quote", n),
    Icon: FileText,
  },
  delivery_note: {
    word: "remito",
    href: (id) => `/remitos/${id}`,
    format: (n) => formatDeliveryNoteNumber("sale", n),
    Icon: Truck,
  },
}

export function SourceDocumentBadge({ kind, documentId, documentNumber, className }: SourceDocumentBadgeProps) {
  const { word, href, format, Icon } = KIND_META[kind]
  const formatted = documentNumber === null ? null : format(documentNumber)
  const label = formatted ? `Desde ${word} ${formatted}` : `Desde ${word}`

  return (
    <Link
      href={href(documentId)}
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
      <Icon className="h-2.5 w-2.5 shrink-0" aria-hidden="true" />
      <span className="truncate">{label}</span>
    </Link>
  )
}
