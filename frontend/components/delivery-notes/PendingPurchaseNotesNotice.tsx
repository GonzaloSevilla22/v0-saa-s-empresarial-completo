"use client"

/**
 * PendingPurchaseNotesNotice — el aviso contra la doble suma (remitos-compra tanda B,
 * D11, tarea 7.9).
 *
 * El escenario que justifica el change es "recibo con remito y la factura llega
 * después". La conversión del remito en compra NO vuelve a sumar el stock, pero hay
 * otras dos puertas que crean una compra directa —y por eso suman el stock otra vez—:
 * el formulario de compra y la Factura IA. Las dos montan este aviso:
 *
 *   - formulario de compra: `supplierId` = el proveedor elegido. Sin proveedor
 *     (`null`) no hay aviso ni se consulta nada: preguntar por los pendientes de toda
 *     la cuenta ahí sería otra pregunta. Con proveedor, cuenta los de ese proveedor;
 *   - Factura IA: sin `supplierId` (el OCR no identifica al proveedor): cuenta los de
 *     toda la cuenta.
 *
 * Es un AVISO (`role="note"`), nunca un bloqueo: una compra directa puede ser
 * legítimamente otra mercadería. Reutiliza `useDeliveryNotes` con `pageSize: 1` (sólo
 * hace falta el total); sin pendientes, mientras carga o si la consulta falla, no
 * muestra nada. Los textos y el destino del enlace salen de `lib/delivery-note-status`.
 */

import Link from "next/link"
import { AlertTriangle } from "lucide-react"
import { useDeliveryNotes } from "@/hooks/data/use-delivery-notes"
import {
  PENDING_PURCHASE_NOTES_LINK_LABEL,
  pendingPurchaseNotesHref,
  pendingPurchaseNotesNotice,
} from "@/lib/delivery-note-status"

interface PendingPurchaseNotesNoticeProps {
  /**
   * Proveedor elegido. `undefined` (omitido): toda la cuenta. `null`: todavía no hay
   * proveedor — no se muestra ni se consulta nada.
   */
  supplierId?: string | null
}

function PendingNoticeBody({ supplierId }: { supplierId?: string }) {
  const { data } = useDeliveryNotes({
    direction: "purchase",
    status: "issued",
    ...(supplierId ? { supplierId } : {}),
    pageSize: 1,
  })

  const text = pendingPurchaseNotesNotice(data?.total ?? 0, supplierId ? "supplier" : "account")
  if (!text) return null

  return (
    <div
      role="note"
      className="flex items-start gap-2 rounded-md border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-foreground"
    >
      <AlertTriangle className="mt-0.5 h-3.5 w-3.5 shrink-0 text-warning" aria-hidden="true" />
      <div className="flex min-w-0 flex-col gap-1">
        <p>{text}</p>
        <Link
          href={pendingPurchaseNotesHref(supplierId)}
          className="w-fit text-primary underline underline-offset-2"
        >
          {PENDING_PURCHASE_NOTES_LINK_LABEL}
        </Link>
      </div>
    </div>
  )
}

export function PendingPurchaseNotesNotice({ supplierId }: PendingPurchaseNotesNoticeProps) {
  // Sin proveedor todavía (formulario de compra): ni aviso ni consulta.
  if (supplierId === null) return null
  return <PendingNoticeBody supplierId={supplierId} />
}
