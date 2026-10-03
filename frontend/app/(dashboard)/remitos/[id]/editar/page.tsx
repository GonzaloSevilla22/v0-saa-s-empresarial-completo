"use client"

/**
 * /remitos/[id]/editar — edición de un remito pendiente (remitos-venta D5/D11), de
 * venta o de compra (remitos-compra D11).
 *
 * Sólo se edita un remito `issued`. Convertido: no se abre el editor, se explica
 * (el mismo `delivery_note_locked_converted` que traduce `operation-errors.ts`:
 * "para corregirlo, eliminá la venta" / "…la compra") y se enlaza a la venta o a
 * la compra. Anulado: se muestra el motivo. Un remito ajeno es indistinguible de
 * uno inexistente.
 *
 * El permiso sigue al SENTIDO del remito, que sólo se sabe cuando carga: un rol
 * sin ninguna de las dos capacidades ve el motivo de inmediato; si tiene una, se
 * espera al remito y se decide con la que le corresponde (el vendedor edita los de
 * venta, no los de compra).
 *
 * El formulario se vuelve a montar cuando cambia la `revision` (otro usuario lo
 * editó y el usuario eligió "Recargar"), y NO cuando sólo se refrescan datos de
 * fondo: así no se pierde lo que se estaba tipeando.
 */
import Link from "next/link"
import { useParams } from "next/navigation"
import { ArrowLeft } from "lucide-react"
import { Button } from "@/components/ui/button"
import { DeliveryNoteForm } from "@/components/delivery-notes/DeliveryNoteForm"
import {
  DELIVERY_NOTE_PAGE_TEXTS,
  DELIVERY_NOTE_SCREEN_TEXTS,
} from "@/components/delivery-notes/delivery-note-page-texts"
import {
  DocumentLoadError,
  DocumentLoading,
  DocumentNoPermission,
  DocumentNotEditable,
} from "@/components/shared/DocumentPageStates"
import { useBranches } from "@/hooks/data/use-branches"
import { useDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useProducts } from "@/hooks/data/use-products"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { canceledReason, deliveryNoteListHref } from "@/lib/delivery-note-status"
import { humanizeOperationError } from "@/lib/operation-errors"
import { CAN_DELIVER_SALE, CAN_RECEIVE_PURCHASE, hasCapability } from "@/lib/rbac-capabilities"

export default function EditDeliveryNotePage() {
  const params = useParams<{ id: string }>()
  const deliveryNoteId = params.id

  const { roles, rolesResolved } = useOrgRole()
  const { isLoading: productsLoading } = useProducts()
  const { isLoading: branchesLoading } = useBranches()
  const { loading: unitsLoading } = useUnitsOfMeasure()
  const { data: note, isLoading, isError } = useDeliveryNote(deliveryNoteId)

  const detailHref = `/remitos/${deliveryNoteId}`
  // Mientras no carga el remito se asume venta (el listado al que vuelve el enlace de error).
  const direction = note?.direction ?? "sale"
  const isPurchase = direction === "purchase"
  const pageTexts = DELIVERY_NOTE_PAGE_TEXTS[direction]
  const screenTexts = DELIVERY_NOTE_SCREEN_TEXTS[direction]
  const canSale = hasCapability(roles, CAN_DELIVER_SALE, rolesResolved)
  const canPurchase = hasCapability(roles, CAN_RECEIVE_PURCHASE, rolesResolved)
  const canEdit = note ? (isPurchase ? canPurchase : canSale) : canSale || canPurchase

  let body: React.ReactNode
  if (!canEdit) {
    body = <DocumentNoPermission texts={pageTexts} action={screenTexts.editAction} />
  } else if (isError) {
    body = <DocumentLoadError texts={pageTexts} />
  } else if (isLoading || !note || productsLoading || unitsLoading || branchesLoading) {
    body = <DocumentLoading label={pageTexts.loadingLabel} />
  } else if (note.status === "converted") {
    const link = isPurchase
      ? note.converted_operation_id
        ? { href: "/compras", label: "Ver la compra" }
        : { href: detailHref, label: "Ver el remito" }
      : note.converted_sales_order_id
        ? { href: `/ventas/ordenes/${note.converted_sales_order_id}`, label: "Ver la venta" }
        : { href: detailHref, label: "Ver el remito" }
    body = (
      <DocumentNotEditable
        texts={pageTexts}
        message={humanizeOperationError("delivery_note_locked_converted", undefined, null, { documentLabel: "remito", direction }).message}
        link={link}
      />
    )
  } else if (note.status === "canceled") {
    const reason = canceledReason(note.history)
    body = (
      <DocumentNotEditable
        texts={pageTexts}
        message="Este remito está anulado y no se puede modificar."
        link={{ href: detailHref, label: "Ver el remito" }}
      >
        {reason && <p className="max-w-md text-sm text-foreground">Motivo: {reason}</p>}
      </DocumentNotEditable>
    )
  } else {
    body = <DeliveryNoteForm key={`${note.id}-${note.revision}`} deliveryNote={note} />
  }

  return (
    <div className="flex flex-col gap-6 min-w-0">
      <div className="flex items-center gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href={note ? detailHref : deliveryNoteListHref(direction)} aria-label="Volver">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            {note?.number_label ? `Editar ${note.number_label}` : "Editar remito"}
          </h1>
          <p className="text-sm text-muted-foreground mt-0.5">{screenTexts.editSubtitle}</p>
        </div>
      </div>
      {body}
    </div>
  )
}
