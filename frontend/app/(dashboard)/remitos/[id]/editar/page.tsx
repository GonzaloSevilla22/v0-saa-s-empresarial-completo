"use client"

/**
 * /remitos/[id]/editar — edición de un remito pendiente (remitos-venta D5/D11).
 *
 * Sólo se edita un remito `issued`. Convertido: no se abre el editor, se explica
 * (el mismo `delivery_note_locked_converted` que traduce `operation-errors.ts`:
 * "para corregirlo, eliminá la venta") y se enlaza a la venta. Anulado: se muestra
 * el motivo. Un remito ajeno es indistinguible de uno inexistente.
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
import { DELIVERY_NOTE_PAGE_TEXTS } from "@/components/delivery-notes/delivery-note-page-texts"
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
import { canceledReason } from "@/lib/delivery-note-status"
import { humanizeOperationError } from "@/lib/operation-errors"
import { CAN_DELIVER_SALE, hasCapability } from "@/lib/rbac-capabilities"

export default function EditDeliveryNotePage() {
  const params = useParams<{ id: string }>()
  const deliveryNoteId = params.id

  const { roles, rolesResolved } = useOrgRole()
  const { isLoading: productsLoading } = useProducts()
  const { isLoading: branchesLoading } = useBranches()
  const { loading: unitsLoading } = useUnitsOfMeasure()
  const { data: note, isLoading, isError } = useDeliveryNote(deliveryNoteId)

  const detailHref = `/remitos/${deliveryNoteId}`

  let body: React.ReactNode
  if (!hasCapability(roles, CAN_DELIVER_SALE, rolesResolved)) {
    body = <DocumentNoPermission texts={DELIVERY_NOTE_PAGE_TEXTS.sale} action="editar remitos" />
  } else if (isError) {
    body = <DocumentLoadError texts={DELIVERY_NOTE_PAGE_TEXTS.sale} />
  } else if (isLoading || !note || productsLoading || unitsLoading || branchesLoading) {
    body = <DocumentLoading label={DELIVERY_NOTE_PAGE_TEXTS.sale.loadingLabel} />
  } else if (note.status === "converted") {
    body = (
      <DocumentNotEditable
        texts={DELIVERY_NOTE_PAGE_TEXTS.sale}
        message={humanizeOperationError("delivery_note_locked_converted", undefined, null, { documentLabel: "remito" }).message}
        link={
          note.converted_sales_order_id
            ? { href: `/ventas/ordenes/${note.converted_sales_order_id}`, label: "Ver la venta" }
            : { href: detailHref, label: "Ver el remito" }
        }
      />
    )
  } else if (note.status === "canceled") {
    const reason = canceledReason(note.history)
    body = (
      <DocumentNotEditable
        texts={DELIVERY_NOTE_PAGE_TEXTS.sale}
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
          <Link href={note ? detailHref : "/remitos"} aria-label="Volver">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0">
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            {note?.number_label ? `Editar ${note.number_label}` : "Editar remito"}
          </h1>
          <p className="text-sm text-muted-foreground mt-0.5">
            Los cambios reemplazan el contenido del remito y ajustan el stock sólo donde cambia.
          </p>
        </div>
      </div>
      {body}
    </div>
  )
}
