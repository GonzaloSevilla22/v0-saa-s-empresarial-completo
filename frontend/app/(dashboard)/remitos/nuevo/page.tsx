"use client"

/**
 * /remitos/nuevo — alta (emisión) de un remito de venta (remitos-venta D11).
 *
 * Acepta `?cliente=<id>` (viene de la ficha del cliente). El `DeliveryNoteForm`
 * rehidrata UNA vez al montar y decide la sucursal por defecto con las
 * sucursales cargadas, así que acá se espera al catálogo, a las unidades y a las
 * sucursales: sin ellos se mostraría un falso "no hay sucursal operativa".
 */
import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DeliveryNoteForm } from "@/components/delivery-notes/DeliveryNoteForm"
import { DELIVERY_NOTE_PAGE_TEXTS } from "@/components/delivery-notes/delivery-note-page-texts"
import { DocumentLoading, DocumentNoPermission } from "@/components/shared/DocumentPageStates"
import { useBranches } from "@/hooks/data/use-branches"
import { useProducts } from "@/hooks/data/use-products"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { CAN_DELIVER_SALE, hasCapability } from "@/lib/rbac-capabilities"

export default function NewDeliveryNotePage() {
  const searchParams = useSearchParams()
  const clientId = searchParams.get("cliente") ?? undefined

  const { roles, rolesResolved } = useOrgRole()
  const { isLoading: productsLoading } = useProducts()
  const { isLoading: branchesLoading } = useBranches()
  const { loading: unitsLoading } = useUnitsOfMeasure()

  let body: React.ReactNode
  if (!hasCapability(roles, CAN_DELIVER_SALE, rolesResolved)) {
    body = <DocumentNoPermission texts={DELIVERY_NOTE_PAGE_TEXTS.sale} action="emitir remitos" />
  } else if (productsLoading || unitsLoading || branchesLoading) {
    body = <DocumentLoading label="Cargando…" />
  } else {
    body = <DeliveryNoteForm initialClientId={clientId} />
  }

  return (
    <div className="flex flex-col gap-6 min-w-0">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href="/remitos" aria-label="Volver al listado">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">Nuevo remito</h1>
          <p className="text-sm text-muted-foreground mt-0.5">
            Documentá la mercadería que entregás. Emitir un remito descuenta stock de la sucursal que elijas.
          </p>
        </div>
      </div>
      {body}
    </div>
  )
}
