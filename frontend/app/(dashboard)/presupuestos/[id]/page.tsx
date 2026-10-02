"use client"

/**
 * /presupuestos/[id] — detalle de un presupuesto (presupuestos-modulo D9/D10).
 *
 * Las acciones por estado y rol salen de `quoteActions` (la tabla de D10), con el
 * rol decidido por `hasCapability` sobre el CONJUNTO de roles. El menú de
 * compartir recibe `onShared` SÓLO cuando el usuario puede marcar como enviado
 * (`CAN_QUOTE` + `draft`): un cajero descarga el PDF sin cambiar el estado, y si
 * marcar como enviado falla no se muestra error (la descarga ya funcionó).
 *
 * "Venta" (tanda B) abre `ConvertQuoteDialog`, la conversión atómica en venta:
 * habilitado en draft/sent vigentes con `CAN_QUOTE`; en uno vencido queda
 * deshabilitado y explicado. En un presupuesto convertido, "Venta generada"
 * enlaza a la orden, muestra el estado de su comprobante y, si la orden se
 * canceló, avisa que la venta fue eliminada (OQ-P12).
 */
import { useCallback, useRef, useState } from "react"
import Link from "next/link"
import { useParams, useRouter } from "next/navigation"
import { ArrowLeft, Ban, Copy, Pencil, Send, ShoppingCart, Trash2 } from "lucide-react"
import { toast } from "sonner"
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog"
import { Button } from "@/components/ui/button"
import { Card, CardContent } from "@/components/ui/card"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { QuoteLoadError, QuoteLoading } from "@/components/quotes/QuotePageStates"
import { ConvertQuoteDialog } from "@/components/quotes/ConvertQuoteDialog"
import { QuoteStatusBadge } from "@/components/quotes/QuoteStatusBadge"
import { FiscalInvoiceSummary } from "@/components/fiscal/FiscalInvoiceSummary"
import { DocumentShareMenu } from "@/components/shared/DocumentShareMenu"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { useProducts } from "@/hooks/data/use-products"
import { fetchQuotePdf, useDeleteQuote, useQuote, useTransitionQuote } from "@/hooks/data/use-quotes"
import { useSalesOrder } from "@/hooks/data/use-sales-orders"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useRestoreFocus } from "@/hooks/ui/use-restore-focus"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { formatDate, formatMoney, formatNumber } from "@/lib/format"
import { mapFiscalState } from "@/lib/fiscal-comprobante"
import { humanizeOperationError } from "@/lib/operation-errors"
import { catalogPriceHint, isModifiedAfterSent, quoteActions, quoteFileName } from "@/lib/quote-detail"
import { QUOTE_STATUS_LABELS } from "@/lib/quote-status"
import { buildQuoteShareText } from "@/lib/quote-share"
import type { PdfDisposition } from "@/lib/api/document-pdf"
import { CAN_QUOTE, hasCapability } from "@/lib/rbac-capabilities"

const SALE_LEGEND_ID = "quote-sale-legend"

function errorMessage(err: unknown): string {
  return humanizeOperationError(err instanceof Error ? err.message : "").message
}

function formatDateTime(iso: string): string {
  return new Date(iso).toLocaleString("es-AR", {
    day: "2-digit",
    month: "2-digit",
    year: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  })
}

export default function QuoteDetailPage() {
  const params = useParams<{ id: string }>()
  const quoteId = params.id
  const router = useRouter()
  const { roles, rolesResolved } = useOrgRole()
  const { products } = useProducts()
  const { unitsById } = useUnitsOfMeasure()
  // Una vez eliminado, la pantalla deja de observar el presupuesto: si siguiera
  // montada, el observador reconstruiría la entrada de caché que borra el hook
  // y volvería a pedir `GET /quotes/<id>` (404) antes de que termine la navegación.
  const [deleted, setDeleted] = useState(false)
  const { data: quote, isLoading, isError } = useQuote(deleted ? null : quoteId)
  const transition = useTransitionQuote()
  const deleteQuote = useDeleteQuote()
  // La orden de la venta generada (sólo en un presupuesto convertido): de ahí
  // salen su estado (¿se canceló?) y el de su comprobante fiscal.
  const { data: generatedOrder } = useSalesOrder(
    quote?.status === "accepted" ? (quote.sales_order_id ?? null) : null,
  )

  const [convertOpen, setConvertOpen] = useState(false)
  const [rejectOpen, setRejectOpen] = useState(false)
  const [rejectReason, setRejectReason] = useState("")
  const [rejecting, setRejecting] = useState(false)
  const [deleteOpen, setDeleteOpen] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [notice, setNotice] = useState("")

  const saleButtonRef = useRef<HTMLButtonElement>(null)
  const rejectButtonRef = useRef<HTMLButtonElement>(null)
  const deleteButtonRef = useRef<HTMLButtonElement>(null)
  useRestoreFocus(convertOpen, saleButtonRef)
  useRestoreFocus(rejectOpen, rejectButtonRef)
  useRestoreFocus(deleteOpen, deleteButtonRef)

  const canQuote = hasCapability(roles, CAN_QUOTE, rolesResolved)

  const fetchPdf = useCallback(
    (disposition: PdfDisposition) => fetchQuotePdf(quoteId, disposition),
    [quoteId],
  )

  /** Compartir/descargar marca como enviado (sólo `draft` con permiso). Un fallo no se muestra. */
  const handleShared = useCallback(async () => {
    try {
      await transition.mutateAsync({ quoteId, action: "send" })
      setNotice("Presupuesto marcado como enviado.")
    } catch {
      // La descarga ya funcionó: el estado se corrige en la próxima lectura.
    }
  }, [transition, quoteId])

  async function handleMarkSent() {
    try {
      await transition.mutateAsync({ quoteId, action: "send" })
      setNotice("Presupuesto marcado como enviado.")
      toast.success("Presupuesto marcado como enviado")
    } catch (err: unknown) {
      toast.error(errorMessage(err))
    }
  }

  async function handleReject() {
    setRejecting(true)
    try {
      await transition.mutateAsync({ quoteId, action: "reject", reason: rejectReason.trim() || undefined })
      toast.success("Presupuesto rechazado")
      setRejectOpen(false)
      setRejectReason("")
    } catch (err: unknown) {
      toast.error(errorMessage(err))
    } finally {
      setRejecting(false)
    }
  }

  async function handleDelete() {
    setDeleting(true)
    try {
      await deleteQuote.mutateAsync(quoteId)
      setDeleted(true)
      toast.success("Presupuesto eliminado")
      router.push("/presupuestos")
    } catch (err: unknown) {
      toast.error(errorMessage(err))
      setDeleteOpen(false)
    } finally {
      setDeleting(false)
    }
  }

  if (isError) return <QuoteLoadError />
  if (isLoading || !quote) return <QuoteLoading />

  const actions = quoteActions(quote, canQuote)
  const numberLabel = quote.number_label ?? "Presupuesto"
  const total = Number(quote.total)
  const validUntilText = quote.valid_until ? formatDate(quote.valid_until) : null
  const expired = quote.status === "expired" || quote.is_expired
  const modifiedAfterSent = isModifiedAfterSent(quote)

  const shareText = buildQuoteShareText({
    clientName: quote.client_name,
    numberLabel,
    total,
    validUntil: quote.valid_until,
    // El emisor del PDF (resuelto por el servidor), no el perfil de quien comparte.
    businessName: quote.issuer_name,
  })

  // Sólo un presupuesto vencido necesita explicar por qué "Venta" no responde.
  const saleLegend = actions.saleBlockedByExpiry
    ? `Vencido el ${validUntilText ?? "—"}: ampliá la validez o duplicalo.`
    : null

  const generatedFiscal = generatedOrder ? mapFiscalState(generatedOrder) : null
  const generatedOrderCanceled = generatedOrder?.status === "canceled"

  return (
    <div className="flex flex-col gap-6 min-w-0">
      {/* ── Cabecera ── */}
      <div className="flex items-start gap-3">
        <Button variant="ghost" size="icon" asChild className="h-8 w-8 shrink-0">
          <Link href="/presupuestos" aria-label="Volver al listado">
            <ArrowLeft className="h-4 w-4" aria-hidden="true" />
          </Link>
        </Button>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h1 className="text-2xl font-bold text-foreground tracking-tight">{numberLabel}</h1>
            <QuoteStatusBadge status={quote.status} isExpired={quote.is_expired} />
          </div>
          <p className="mt-1 text-sm text-muted-foreground">
            {quote.client_id ? (
              <Link href={`/clientes/${quote.client_id}`} className="text-primary underline-offset-2 hover:underline">
                {quote.client_name ?? "Cliente"}
              </Link>
            ) : (
              "Sin cliente"
            )}
            {quote.client_phone ? <span> · Tel. {quote.client_phone}</span> : null}
          </p>
          <dl className="mt-3 grid grid-cols-2 gap-x-6 gap-y-1 text-xs text-muted-foreground sm:flex sm:flex-wrap">
            <div className="flex gap-1">
              <dt>Creado:</dt>
              <dd className="tabular-nums text-foreground">{formatDate(quote.created_at)}</dd>
            </div>
            {quote.sent_at && (
              <div className="flex gap-1">
                <dt>Enviado:</dt>
                <dd className="tabular-nums text-foreground">{formatDate(quote.sent_at)}</dd>
              </div>
            )}
            <div className="flex gap-1">
              <dt>Válido hasta:</dt>
              <dd className={`tabular-nums ${expired ? "font-medium text-destructive" : "text-foreground"}`}>
                {validUntilText ?? "—"}
              </dd>
            </div>
          </dl>
        </div>
      </div>

      {/* ── Avisos ── */}
      {expired && quote.status !== "accepted" && (
        <p
          role="status"
          aria-label="Presupuesto vencido"
          className="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
        >
          Vencido el {validUntilText ?? "—"}: editalo para ampliar la validez o duplicalo.
        </p>
      )}
      {modifiedAfterSent && (
        <p
          role="status"
          aria-label="Modificado después de enviado"
          className="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
        >
          Modificado después de enviado — reenvialo para que el cliente tenga la versión vigente.
        </p>
      )}
      {quote.status === "accepted" && (
        <section
          aria-label="Venta generada"
          className="flex flex-col gap-3 rounded-lg border border-success/30 bg-success/10 px-4 py-3 text-sm text-foreground"
        >
          {generatedOrderCanceled ? (
            <>
              <p className="font-medium">La venta generada fue eliminada.</p>
              <p className="text-muted-foreground">
                Este presupuesto no se reabre: para volver a vender, duplicá el presupuesto.
              </p>
            </>
          ) : (
            <div className="flex flex-wrap items-center justify-between gap-3">
              <p>Este presupuesto se convirtió en una venta.</p>
              {quote.sales_order_id && (
                <Button asChild size="sm" variant="outline">
                  <Link href={`/ventas/ordenes/${quote.sales_order_id}`}>Ver venta</Link>
                </Button>
              )}
            </div>
          )}
          {!generatedOrderCanceled && generatedOrder && (
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
        <div className="flex flex-wrap items-center gap-2">
          <DocumentShareMenu
            fetchPdf={fetchPdf}
            fileName={quoteFileName(quote.number_label)}
            shareText={shareText}
            shareTitle={`Presupuesto ${numberLabel}`}
            clientPhone={quote.client_phone}
            onShared={actions.markSentOnShare ? handleShared : undefined}
          />
          {actions.canEdit && (
            <Button asChild variant="outline" size="sm" className="gap-1.5">
              <Link href={`/presupuestos/${quote.id}/editar`}>
                <Pencil className="h-4 w-4" aria-hidden="true" />
                Editar
              </Link>
            </Button>
          )}
          {actions.canMarkSent && (
            <Button
              type="button"
              variant="outline"
              size="sm"
              className="gap-1.5"
              onClick={() => void handleMarkSent()}
              disabled={transition.isPending}
            >
              <Send className="h-4 w-4" aria-hidden="true" />
              Marcar como enviado
            </Button>
          )}
          {actions.showSaleButton && (
            <Button
              ref={saleButtonRef}
              type="button"
              size="sm"
              className="gap-1.5"
              disabled={!actions.canConvert}
              aria-describedby={saleLegend ? SALE_LEGEND_ID : undefined}
              onClick={() => setConvertOpen(true)}
            >
              <ShoppingCart className="h-4 w-4" aria-hidden="true" />
              Venta
            </Button>
          )}
          {actions.canDuplicate && (
            <Button asChild variant="outline" size="sm" className="gap-1.5">
              <Link href={`/presupuestos/nuevo?duplicar=${quote.id}`}>
                <Copy className="h-4 w-4" aria-hidden="true" />
                Duplicar
              </Link>
            </Button>
          )}
          {actions.canReject && (
            <Button
              ref={rejectButtonRef}
              type="button"
              variant="outline"
              size="sm"
              className="gap-1.5"
              onClick={() => setRejectOpen(true)}
            >
              <Ban className="h-4 w-4" aria-hidden="true" />
              Rechazar
            </Button>
          )}
          {actions.canDelete && (
            <Button
              ref={deleteButtonRef}
              type="button"
              variant="outline"
              size="sm"
              className="gap-1.5 border-destructive/40 text-destructive hover:bg-destructive/10"
              onClick={() => setDeleteOpen(true)}
            >
              <Trash2 className="h-4 w-4" aria-hidden="true" />
              Eliminar
            </Button>
          )}
        </div>
        {saleLegend && (
          <p id={SALE_LEGEND_ID} className="text-xs text-muted-foreground">
            {saleLegend}
          </p>
        )}
        <p role="status" aria-live="polite" aria-label="Aviso de envío" className="text-xs text-success">
          {notice}
        </p>
      </div>

      {/* ── Líneas ── */}
      <Card className="border-border bg-card min-w-0">
        <CardContent className="p-0">
          <div className="overflow-x-auto">
            <table aria-label="Líneas del presupuesto" className="w-full text-sm">
              <thead>
                <tr className="border-b border-border text-left">
                  <th scope="col" className="px-2 py-3 sm:px-4 font-medium text-muted-foreground">Descripción</th>
                  <th scope="col" className="px-2 py-3 sm:px-4 text-right font-medium text-muted-foreground">Cant.</th>
                  <th scope="col" className="px-2 py-3 sm:px-4 text-right font-medium text-muted-foreground">Precio unit.</th>
                  <th scope="col" className="px-2 py-3 sm:px-4 text-right font-medium text-muted-foreground">Subtotal</th>
                </tr>
              </thead>
              <tbody>
                {quote.items.map((item) => {
                  const hint = catalogPriceHint(item, products, unitsById)
                  return (
                    <tr key={item.id} className="border-b border-border/50 last:border-b-0">
                      <td className="px-2 py-3 sm:px-4 break-words text-foreground">{item.name_snapshot ?? "—"}</td>
                      <td className="px-2 py-3 sm:px-4 text-right tabular-nums whitespace-nowrap">
                        {formatNumber(Number(item.quantity), 4)}
                        {item.unit_symbol ? ` ${item.unit_symbol}` : ""}
                      </td>
                      <td className="px-2 py-3 sm:px-4 text-right tabular-nums whitespace-nowrap">
                        {formatMoney(Number(item.price))}
                        {hint !== null && (
                          <span className="block text-[11px] text-muted-foreground">
                            Lista hoy: {formatMoney(hint)}
                          </span>
                        )}
                      </td>
                      <td className="px-2 py-3 sm:px-4 text-right font-medium tabular-nums whitespace-nowrap text-foreground">
                        {formatMoney(Number(item.subtotal))}
                      </td>
                    </tr>
                  )
                })}
              </tbody>
            </table>
          </div>
          <div className="flex items-center justify-between gap-4 border-t border-border px-4 py-3">
            <span className="text-sm text-muted-foreground">Total</span>
            <span data-testid="quote-total" className="text-xl font-bold tabular-nums text-primary">
              {formatMoney(total)}
            </span>
          </div>
        </CardContent>
      </Card>

      {quote.notes && (
        <section aria-label="Notas" className="rounded-lg border border-border bg-card px-4 py-3">
          <h2 className="text-xs font-semibold uppercase tracking-wider text-muted-foreground">Notas y condiciones</h2>
          <p className="mt-1 whitespace-pre-wrap text-sm text-foreground">{quote.notes}</p>
        </section>
      )}

      {/* ── Historial ── */}
      <section aria-labelledby="quote-history-title" className="flex flex-col gap-2">
        <h2 id="quote-history-title" className="text-sm font-semibold text-foreground">
          Historial
        </h2>
        <ul aria-label="Historial de estados" className="flex flex-col gap-1.5 text-sm">
          {quote.history.map((entry, index) => (
            <li
              key={`${entry.occurred_at}-${index}`}
              className="flex flex-wrap items-baseline gap-x-2 rounded-md border border-border/60 bg-card px-3 py-2"
            >
              <span className="font-medium text-foreground">{QUOTE_STATUS_LABELS[entry.to_status]}</span>
              <span className="text-xs tabular-nums text-muted-foreground">{formatDateTime(entry.occurred_at)}</span>
              {entry.reason && <span className="text-xs text-muted-foreground">— {entry.reason}</span>}
            </li>
          ))}
        </ul>
      </section>

      {/* ── Pasar a venta ──
          Se mantiene montado mientras esté abierto: al convertir, el presupuesto
          pasa a `accepted` (y deja de ofrecer "Venta"), pero el diálogo tiene que
          seguir ahí para mostrar "Venta registrada" hasta que el usuario lo cierre. */}
      {canQuote && (actions.canConvert || convertOpen) && (
        <ConvertQuoteDialog quote={quote} open={convertOpen} onOpenChange={setConvertOpen} />
      )}

      {/* ── Rechazar ── */}
      <ResponsiveModal open={rejectOpen} onOpenChange={setRejectOpen} title="Rechazar presupuesto">
        <div className="flex flex-col gap-3">
          <p className="text-sm text-muted-foreground">
            Se marca como rechazado (por ejemplo, si el cliente no lo aceptó). Después se puede editar para reabrirlo.
          </p>
          <div className="flex flex-col gap-2">
            <Label htmlFor="quote-reject-reason" className="text-foreground">
              Motivo (opcional)
            </Label>
            <Textarea
              id="quote-reject-reason"
              value={rejectReason}
              maxLength={500}
              onChange={(e) => setRejectReason(e.target.value)}
              placeholder="Ej: lo encontró más barato en otro lado"
              rows={3}
              className="bg-background border-border text-foreground"
            />
          </div>
          <div className="flex justify-end gap-2">
            <Button type="button" variant="outline" onClick={() => setRejectOpen(false)} disabled={rejecting}>
              Cancelar
            </Button>
            <Button type="button" onClick={() => void handleReject()} disabled={rejecting}>
              {rejecting ? "Rechazando…" : "Rechazar presupuesto"}
            </Button>
          </div>
        </div>
      </ResponsiveModal>

      {/* ── Eliminar ── */}
      <AlertDialog open={deleteOpen} onOpenChange={setDeleteOpen}>
        <AlertDialogContent className="bg-card border-border">
          <AlertDialogHeader>
            <AlertDialogTitle className="text-card-foreground">¿Eliminar {numberLabel}?</AlertDialogTitle>
            <AlertDialogDescription className="text-muted-foreground">
              Es un borrador que nunca se envió: se elimina por completo y no se puede recuperar.
            </AlertDialogDescription>
          </AlertDialogHeader>
          <AlertDialogFooter>
            <AlertDialogCancel className="border-border text-foreground" disabled={deleting}>
              Cancelar
            </AlertDialogCancel>
            <AlertDialogAction
              disabled={deleting}
              onClick={(event) => {
                // El diálogo queda abierto hasta que el servidor responda.
                event.preventDefault()
                void handleDelete()
              }}
            >
              Eliminar
            </AlertDialogAction>
          </AlertDialogFooter>
        </AlertDialogContent>
      </AlertDialog>
    </div>
  )
}
