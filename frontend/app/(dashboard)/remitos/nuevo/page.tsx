"use client"

/**
 * /remitos/nuevo — alta (emisión) de un remito de venta (remitos-venta D11) o de
 * compra (remitos-compra D11, `?tipo=compra`).
 *
 * Acepta `?cliente=<id>` (viene de la ficha del cliente) y, en compra,
 * `?proveedor=<id>` (viene de /proveedores). El permiso sigue al sentido: emitir un
 * remito de venta es `CAN_DELIVER_SALE`; recibir mercadería, `CAN_RECEIVE_PURCHASE`
 * (el vendedor despacha pero no recibe). El `DeliveryNoteForm`
 * rehidrata UNA vez al montar y decide la sucursal por defecto con las
 * sucursales cargadas, así que acá se espera al catálogo, a las unidades y a las
 * sucursales: sin ellos se mostraría un falso "no hay sucursal operativa".
 */
import Link from "next/link"
import { useSearchParams } from "next/navigation"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DeliveryNoteForm } from "@/components/delivery-notes/DeliveryNoteForm"
import {
  DELIVERY_NOTE_PAGE_TEXTS,
  DELIVERY_NOTE_SCREEN_TEXTS,
} from "@/components/delivery-notes/delivery-note-page-texts"
import { DocumentLoading, DocumentNoPermission } from "@/components/shared/DocumentPageStates"
import { useBranches } from "@/hooks/data/use-branches"
import { useProducts } from "@/hooks/data/use-products"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import {
  deliveryNoteListHref,
  directionFromSentido,
  parseDeliveryNoteSentidoParam,
} from "@/lib/delivery-note-status"
import { CAN_DELIVER_SALE, CAN_RECEIVE_PURCHASE, hasCapability } from "@/lib/rbac-capabilities"

export default function NewDeliveryNotePage() {
  const searchParams = useSearchParams()
  const direction = directionFromSentido(parseDeliveryNoteSentidoParam(searchParams.get("tipo")))
  const isPurchase = direction === "purchase"
  const clientId = isPurchase ? undefined : (searchParams.get("cliente") ?? undefined)
  const supplierId = isPurchase ? (searchParams.get("proveedor") ?? undefined) : undefined
  const pageTexts = DELIVERY_NOTE_PAGE_TEXTS[direction]
  const screenTexts = DELIVERY_NOTE_SCREEN_TEXTS[direction]

  const { roles, rolesResolved } = useOrgRole()
  const { isLoading: productsLoading } = useProducts()
  const { isLoading: branchesLoading } = useBranches()
  const { loading: unitsLoading } = useUnitsOfMeasure()

  let body: React.ReactNode
  if (!hasCapability(roles, isPurchase ? CAN_RECEIVE_PURCHASE : CAN_DELIVER_SALE, rolesResolved)) {
    body = <DocumentNoPermission texts={pageTexts} action={screenTexts.newAction} />
  } else if (productsLoading || unitsLoading || branchesLoading) {
    body = <DocumentLoading label="Cargando…" />
  } else {
    body = <DeliveryNoteForm direction={direction} initialClientId={clientId} initialSupplierId={supplierId} />
  }

  return (
    <div className="flex flex-col gap-6 min-w-0">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href={deliveryNoteListHref(direction)} aria-label="Volver al listado">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">{screenTexts.newTitle}</h1>
          <p className="text-sm text-muted-foreground mt-0.5">{screenTexts.newSubtitle}</p>
        </div>
      </div>
      {body}
    </div>
  )
}
