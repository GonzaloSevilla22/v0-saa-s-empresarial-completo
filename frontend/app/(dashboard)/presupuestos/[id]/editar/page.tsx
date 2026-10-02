"use client"

/**
 * /presupuestos/[id]/editar — edición de un presupuesto (presupuestos-modulo D5).
 *
 * Editable en todo estado salvo `accepted` (convertido en venta): ahí no se abre
 * el editor, se explica el motivo (el mismo `P0423` que traduce
 * `operation-errors.ts`) y se enlaza al detalle. Editar un vencido o rechazado lo
 * reabre como borrador; el aviso lo da el propio `QuoteForm`.
 *
 * El formulario se vuelve a montar cuando cambia la `revision` (otro usuario lo
 * editó y el usuario eligió "Recargar"), y NO cuando sólo se refrescan datos de
 * fondo: así no se pierde lo que se estaba tipeando.
 */
import Link from "next/link"
import { useParams } from "next/navigation"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"
import { QuoteForm } from "@/components/quotes/QuoteForm"
import { QuoteLoadError, QuoteLoading, QuoteNoPermission } from "@/components/quotes/QuotePageStates"
import { useProducts } from "@/hooks/data/use-products"
import { useQuote } from "@/hooks/data/use-quotes"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { humanizeOperationError } from "@/lib/operation-errors"
import { CAN_QUOTE, hasCapability } from "@/lib/rbac-capabilities"

export default function EditQuotePage() {
  const params = useParams<{ id: string }>()
  const quoteId = params.id

  const { roles, rolesResolved } = useOrgRole()
  const { isLoading: productsLoading } = useProducts()
  const { loading: unitsLoading } = useUnitsOfMeasure()
  const { data: quote, isLoading, isError } = useQuote(quoteId)

  let body: React.ReactNode
  if (!hasCapability(roles, CAN_QUOTE, rolesResolved)) {
    body = <QuoteNoPermission action="editar presupuestos" />
  } else if (isError) {
    body = <QuoteLoadError />
  } else if (isLoading || !quote || productsLoading || unitsLoading) {
    body = <QuoteLoading />
  } else if (quote.status === "accepted") {
    body = (
      <div className="flex flex-col items-center gap-3 px-4 py-10 text-center">
        <p role="status" className="max-w-lg text-sm text-muted-foreground">
          {humanizeOperationError("quote_locked_converted").message}
        </p>
        <Button asChild variant="outline" size="sm">
          <Link href={`/presupuestos/${quote.id}`}>Ver el presupuesto</Link>
        </Button>
      </div>
    )
  } else {
    body = <QuoteForm key={`${quote.id}-${quote.revision}`} quote={quote} />
  }

  return (
    <div className="flex flex-col gap-6 min-w-0">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href={quote ? `/presupuestos/${quote.id}` : "/presupuestos"} aria-label="Volver">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            {quote?.number_label ? `Editar ${quote.number_label}` : "Editar presupuesto"}
          </h1>
          <p className="text-sm text-muted-foreground mt-0.5">
            Los cambios reemplazan el contenido del presupuesto; el estado se conserva.
          </p>
        </div>
      </div>
      {body}
    </div>
  )
}
