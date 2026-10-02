"use client"

/**
 * /presupuestos/nuevo — alta de un presupuesto (presupuestos-modulo D10/D12).
 *
 * Acepta `?cliente=<id>` (viene de la ficha del cliente) y `?duplicar=<id>`
 * (precarga cliente, notas y líneas de otro presupuesto, con los precios de
 * hoy). El `QuoteForm` rehidrata UNA vez al montar, así que acá se espera al
 * catálogo y a las unidades: con el catálogo vacío todos los productos
 * figurarían como "no disponibles".
 */
import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"
import { QuoteForm } from "@/components/quotes/QuoteForm"
import { QuoteLoadError, QuoteLoading, QuoteNoPermission } from "@/components/quotes/QuotePageStates"
import { useProducts } from "@/hooks/data/use-products"
import { useQuote } from "@/hooks/data/use-quotes"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { CAN_QUOTE, hasCapability } from "@/lib/rbac-capabilities"

export default function NewQuotePage() {
  const searchParams = useSearchParams()
  const clientId = searchParams.get("cliente") ?? undefined
  const duplicateId = searchParams.get("duplicar")

  const { roles, rolesResolved } = useOrgRole()
  const { isLoading: productsLoading } = useProducts()
  const { loading: unitsLoading } = useUnitsOfMeasure()
  const source = useQuote(duplicateId)

  let body: React.ReactNode
  if (!hasCapability(roles, CAN_QUOTE, rolesResolved)) {
    body = <QuoteNoPermission action="crear presupuestos" />
  } else if (duplicateId && source.isError) {
    body = <QuoteLoadError />
  } else if (productsLoading || unitsLoading || (duplicateId && (source.isLoading || !source.data))) {
    body = <QuoteLoading label="Cargando…" />
  } else {
    body = duplicateId ? (
      <QuoteForm key={`duplicate-${duplicateId}`} duplicateFrom={source.data} />
    ) : (
      <QuoteForm initialClientId={clientId} />
    )
  }

  return (
    <div className="flex flex-col gap-6 min-w-0">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href="/presupuestos" aria-label="Volver al listado">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Nuevo presupuesto</h1>
          <p className="text-sm text-muted-foreground mt-0.5">
            {duplicateId ? "Copia de otro presupuesto, con los precios de hoy." : "Cotizá a un cliente sin tocar el stock."}
          </p>
        </div>
      </div>
      {body}
    </div>
  )
}
