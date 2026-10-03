"use client"

/**
 * /remitos/[id] — detalle de un remito de venta (remitos-venta D11, tarea 5.6).
 *
 * Las acciones por estado y rol salen de `deliveryNoteActions` (la matriz de
 * D11), con el rol decidido por `hasCapability` sobre el CONJUNTO de roles:
 *
 *  - `issued`: compartir, editar (`CAN_DELIVER_SALE`) y anular
 *    (`CAN_VOID_DELIVERY_NOTE`). "Venta" (convertir en venta) llega con la tanda B
 *    y por eso no se muestra todavía (`conversionEnabled` apagado).
 *  - `converted`: compartir y ver la venta, con la leyenda "para corregirlo,
 *    eliminá la venta: el remito vuelve a quedar pendiente"; si la venta ya
 *    tiene comprobante autorizado, la de la nota de crédito (D9).
 *  - `canceled`: sólo compartir (PDF con el sello ANULADO) y el motivo.
 *
 * Compartir es el menú compartido (`DocumentShareMenu`) con el switch "Mostrar
 * precios" (apagado por defecto: el remito no lleva precios, R2). El switch es
 * un control HERMANO, fuera del desplegable, con su `Label`: el menú precarga el
 * PDF una sola vez al abrirse, así que cambiar el switch con el menú ya preparado
 * compartiría la variante anterior. Por eso `fetchPdf` cierra sobre el estado del
 * switch y el menú se monta con `key={showPrices}`: cambiarlo descarta la
 * precarga. Compartir NO cambia el estado del remito (no hay "enviado").
 */
import { useCallback, useRef, useState } from "react"
import Link from "next/link"
import { useParams } from "next/navigation"
import { ArrowLeft, Ban, Pencil } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { Switch } from "@/components/ui/switch"
import { CancelDeliveryNoteDialog } from "@/components/delivery-notes/CancelDeliveryNoteDialog"
import { DELIVERY_NOTE_PAGE_TEXTS } from "@/components/delivery-notes/delivery-note-page-texts"
import { DeliveryNoteStatusBadge } from "@/components/delivery-notes/DeliveryNoteStatusBadge"
import { FiscalInvoiceSummary } from "@/components/fiscal/FiscalInvoiceSummary"
import { DocumentShareMenu } from "@/components/shared/DocumentShareMenu"
import { DocumentLoadError, DocumentLoading } from "@/components/shared/DocumentPageStates"
import { fetchDeliveryNotePdf, useDeliveryNote } from "@/hooks/data/use-delivery-notes"
import { useSalesOrder } from "@/hooks/data/use-sales-orders"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useRestoreFocus } from "@/hooks/ui/use-restore-focus"
import type { PdfDisposition } from "@/lib/api/document-pdf"
import { buildDeliveryNoteShareText, deliveryNoteFileName } from "@/lib/delivery-note-share"
import { canceledReason, deliveryNoteActions, deliveryNoteHistoryLabel } from "@/lib/delivery-note-status"
import { mapFiscalState } from "@/lib/fiscal-comprobante"
import { formatDate, formatMoney, formatNumber } from "@/lib/format"
import { CAN_DELIVER_SALE, CAN_SELL, CAN_VOID_DELIVERY_NOTE, hasCapability } from "@/lib/rbac-capabilities"

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString("es-AR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  })
}

export default function DeliveryNoteDetailPage() {
  const params = useParams<{ id: string }>()
  const deliveryNoteId = params.id
  const { roles, rolesResolved } = useOrgRole()
  const { data: note, isLoading, isError } = useDeliveryNote(deliveryNoteId)
  // La orden de la venta generada (sólo en un remito convertido): de ahí sale el
  // estado de su comprobante fiscal.
  const { data: generatedOrder } = useSalesOrder(note?.status === "converted" ? (note.converted_sales_order_id ?? null) : null)

  const [showPrices, setShowPrices] = useState(false)
  const [cancelOpen, setCancelOpen] = useState(false)
  const cancelButtonRef = useRef<HTMLButtonElement>(null)
  useRestoreFocus(cancelOpen, cancelButtonRef)

  const fetchPdf = useCallback(
    (disposition: PdfDisposition) => fetchDeliveryNotePdf(deliveryNoteId, disposition, showPrices),
    [deliveryNoteId, showPrices],
  )

  if (isError) return <DocumentLoadError texts={DELIVERY_NOTE_PAGE_TEXTS} />
  if (isLoading || !note) return <DocumentLoading label={DELIVERY_NOTE_PAGE_TEXTS.loadingLabel} />

  const generatedFiscal = generatedOrder ? mapFiscalState(generatedOrder) : null
  const actions = deliveryNoteActions(note.status, {
    canDeliver: hasCapability(roles, CAN_DELIVER_SALE, rolesResolved),
    canSell: hasCapability(roles, CAN_SELL, rolesResolved),
    canVoid: hasCapability(roles, CAN_VOID_DELIVERY_NOTE, rolesResolved),
    clientDeleted: note.client_deleted,
    // La conversión en venta es de la tanda B: hasta entonces "Venta" no existe.
    conversionEnabled: false,
    saleInvoiced: generatedFiscal?.status === "authorized",
  })

  const numberLabel = note.number_label ?? "Remito"
  const reason = canceledReason(note.history)
  const branchName = note.branch_name ?? "la sucursal"
  const shareText = buildDeliveryNoteShareText({
    clientName: note.client_name,
    numberLabel: note.number_label ?? null,
    issuedOn: note.issued_on,
    // El emisor del PDF (resuelto por el servidor), no el perfil de quien comparte.
    businessName: note.issuer_name,
  })

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Cabecera ── */}
      <div className="flex items-start gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href="/remitos" aria-label="Volver al listado">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-2xl font-bold text-foreground tracking-tight">{numberLabel}</h1>
            <DeliveryNoteStatusBadge status={note.status} />
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {note.client_id && !note.client_deleted ? (
              <Link href={`/clientes/${note.client_id}`} className="text-primary underline-offset-2 hover:underline">
                {note.client_name ?? "Cliente"}
              </Link>
            ) : (
              <span className="text-foreground">{note.client_name ?? "Sin cliente"}</span>
            )}
            {note.client_deleted ? <span> · Cliente dado de baja</span> : null}
            {note.client_phone ? <span> · Tel. {note.client_phone}</span> : null}
          </p>
          <dl className="mt-3 grid grid-cols-1 gap-x-6 gap-y-1 text-xs text-muted-foreground sm:flex sm:flex-wrap">
            <div className="flex gap-1">
              <dt>Sale de:</dt>
              <dd className="text-foreground">{branchName}</dd>
            </div>
            <div className="flex gap-1">
              <dt>Fecha:</dt>
              <dd className="tabular-nums text-foreground">{formatDate(note.issued_on)}</dd>
            </div>
            {note.revision > 1 && note.updated_at && (
              <div className="flex gap-1">
                <dt>Modificado el</dt>
                <dd className="tabular-nums text-foreground">{formatDateTime(note.updated_at)}</dd>
              </div>
            )}
            {note.delivery_address && (
              <div className="flex gap-1 sm:basis-full">
                <dt className="shrink-0">Entrega en:</dt>
                <dd className="break-words text-foreground">{note.delivery_address}</dd>
              </div>
            )}
          </dl>
        </div>
      </div>

      {/* ── Avisos de estado ── */}
      {note.status === "canceled" && (
        <p
          role="status"
          aria-label="Remito anulado"
          className="rounded-lg border border-destructive/30 bg-destructive/10 px-4 py-3 text-sm text-foreground"
        >
          Remito anulado: el stock volvió a {branchName}.
          {reason ? (
            <>
              {" "}
              Motivo: <span className="font-medium">{reason}</span>
            </>
          ) : null}
        </p>
      )}
      {note.status === "converted" && (
        <section
          aria-label="Venta generada"
          className="flex flex-col gap-3 rounded-lg border border-success/30 bg-success/10 px-4 py-3 text-sm text-foreground"
        >
          <p>Este remito se convirtió en una venta. El stock ya se había descontado al emitirlo.</p>
          {generatedOrder && (
            <div className="min-w-0">
              {generatedFiscal ? (
                <FiscalInvoiceSummary fiscal={generatedFiscal} />
              ) : (
                <p className="text-xs text-muted-foreground">Sin comprobante emitido.</p>
              )}
            </div>
          )}
        </section>
      )}

      {/* ── Acciones ── */}
      <div className="flex flex-col gap-2">
        <div className="flex flex-wrap items-center gap-x-4 gap-y-2">
          {actions.share && (
            <div className="flex flex-wrap items-center gap-3">
              <DocumentShareMenu
                key={String(showPrices)}
                fetchPdf={fetchPdf}
                fileName={deliveryNoteFileName(note.number_label ?? null, showPrices)}
                shareText={shareText}
                shareTitle={`Remito ${numberLabel}`}
                clientPhone={note.client_phone}
              />
              <div className="flex items-center gap-2">
                <Switch id="delivery-note-show-prices" checked={showPrices} onCheckedChange={setShowPrices} />
                <Label htmlFor="delivery-note-show-prices" className="cursor-pointer text-sm text-foreground">
                  Mostrar precios
                </Label>
              </div>
            </div>
          )}
          <div className="flex flex-wrap items-center gap-2">
            {actions.edit && (
              <Button asChild variant="outline" size="sm" className="gap-1.5">
                <Link href={`/remitos/${note.id}/editar`}>
                  <Pencil className="h-4 w-4" aria-hidden="true" />
                  Editar
                </Link>
              </Button>
            )}
            {actions.viewSale && note.converted_sales_order_id && (
              <Button asChild variant="outline" size="sm">
                <Link href={`/ventas/ordenes/${note.converted_sales_order_id}`}>Ver venta</Link>
              </Button>
            )}
            {actions.cancel && (
              <Button
                ref={cancelButtonRef}
                type="button"
                variant="outline"
                size="sm"
                className="gap-1.5 border-destructive/40 text-destructive hover:bg-destructive/10"
                onClick={() => setCancelOpen(true)}
              >
                <Ban className="h-4 w-4" aria-hidden="true" />
                Anular
              </Button>
            )}
          </div>
        </div>
        {actions.legend && <p className="text-xs text-muted-foreground">{actions.legend}</p>}
      </div>

      {/* ── Líneas ── */}
      <Card className="border-border bg-card min-w-0">
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table aria-label="Líneas del remito" className="w-full text-sm">
              <thead>
                <tr className="border-b border-border text-left">
                  <th scope="col" className="px-2 py-3 sm:px-4 font-medium text-muted-foreground">Producto</th>
                  <th scope="col" className="px-2 py-3 sm:px-4 text-right font-medium text-muted-foreground">Cant.</th>
                  <th scope="col" className="px-2 py-3 sm:px-4 text-right font-medium text-muted-foreground">Precio unit.</th>
                  <th scope="col" className="px-2 py-3 sm:px-4 text-right font-medium text-muted-foreground">Subtotal</th>
                </tr>
              </thead>
              <tbody>
                {note.items.map((line) => (
                  <tr key={line.id} className="border-b border-border/50 last:border-b-0">
                    <td className="px-2 py-3 sm:px-4 break-words text-foreground">
                      {line.name_snapshot ?? "—"}
                      {line.product_deleted && (
                        <span className="block text-[11px] text-muted-foreground">Producto dado de baja</span>
                      )}
                    </td>
                    <td className="px-2 py-3 sm:px-4 text-right tabular-nums whitespace-nowrap">
                      {formatNumber(Number(line.quantity), 4)}
                      {line.unit_symbol ? ` ${line.unit_symbol}` : ""}
                    </td>
                    <td className="px-2 py-3 sm:px-4 text-right tabular-nums whitespace-nowrap">
                      {formatMoney(Number(line.price))}
                    </td>
                    <td className="px-2 py-3 sm:px-4 text-right font-medium tabular-nums whitespace-nowrap text-foreground">
                      {formatMoney(Number(line.subtotal))}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between gap-4 border-t border-border px-4 py-3">
            <span className="text-sm text-muted-foreground">Total</span>
            <span data-testid="delivery-note-total" className="text-xl font-bold tabular-nums text-primary">
              {formatMoney(Number(note.total))}
            </span>
          </div>
        </CardContent>
      </Card>

      {note.notes && (
        <section aria-label="Notas" className="rounded-lg border border-border bg-card px-4 py-3">
          <h2 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Notas</h2>
          <p className="mt-1 whitespace-pre-wrap text-sm text-foreground">{note.notes}</p>
        </section>
      )}

      {/* ── Historial ── */}
      <section aria-labelledby="delivery-note-history-title" className="flex flex-col gap-2">
        <h2 id="delivery-note-history-title" className="text-sm font-semibold text-foreground">
          Historial
        </h2>
        <ul aria-label="Historial de estados" className="flex flex-col gap-1.5 text-sm">
          {note.history.map((entry, index) => (
            <li
              key={`${entry.occurred_at}-${index}`}
              className="flex flex-wrap items-baseline gap-x-2 rounded-md border border-border/60 bg-card px-3 py-2"
            >
              <span className="font-medium text-foreground">{deliveryNoteHistoryLabel(entry)}</span>
              <span className="text-xs tabular-nums text-muted-foreground">{formatDateTime(entry.occurred_at)}</span>
              {entry.reason && <span className="text-xs text-muted-foreground">— {entry.reason}</span>}
            </li>
          ))}
        </ul>
      </section>

      {/* ── Anular ── */}
      {actions.cancel && <CancelDeliveryNoteDialog deliveryNote={note} open={cancelOpen} onOpenChange={setCancelOpen} />}
    </div>
  )
}
