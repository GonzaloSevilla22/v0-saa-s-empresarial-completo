"use client"

/**
 * presupuestos-modulo (D12) — formulario de alta, edición y duplicado de un
 * presupuesto.
 *
 * Se arma con las piezas compartidas del carrito de la venta y NO lleva lógica
 * de carrito propia: el despacho de un código, el alta manual, los reductores
 * de línea y el armado del payload viven en `lib/cart-utils`,
 * `lib/quote-lines` y `lib/quote-form`. La diferencia con la venta es una
 * bandera (`enforceStock: false`): el presupuesto no reserva ni baja stock, así
 * que lo que supera el disponible se agrega igual y sólo se avisa.
 *
 *  - **Alta**: cliente obligatorio (con alta en el lugar), líneas de producto y
 *    conceptos, validez con el default de la cuenta y notas.
 *  - **Edición**: reemplazo completo con la `revision` que se cargó; si otro
 *    usuario lo modificó, `quote_changed` ofrece recargar sin pisarlo. Editar un
 *    vencido o rechazado lo reabre como borrador y exige validez de hoy en
 *    adelante.
 *  - **Duplicado**: cliente, notas y líneas al precio de HOY, con el aviso de lo
 *    que cambió (los descuentos no se copian).
 */
import { useCallback, useId, useMemo, useRef, useState } from "react"
import { useRouter } from "next/navigation"
import { useQueryClient } from "@tanstack/react-query"
import { AlertTriangle, Plus, RefreshCw, ShoppingCart, UserPlus } from "lucide-react"
import { toast } from "sonner"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { NumericInput } from "@/components/ui/numeric-input"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { Textarea } from "@/components/ui/textarea"
import { BranchSelect } from "@/components/branches/BranchSelect"
import { ClientForm } from "@/components/forms/client-form"
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { CartItemList, type CartDisplayItem } from "@/components/shared/cart-item-list"
import { ResponsiveModal } from "@/components/shared/responsive-modal"
import { ScrollableCartShell } from "@/components/shared/scrollable-cart-shell"
import { StagedProductLine, type StagedProductLineHandle } from "@/components/shared/StagedProductLine"
import { useClients } from "@/hooks/data/use-clients"
import { useProducts } from "@/hooks/data/use-products"
import { useCreateQuote, useQuoteSettings, useUpdateQuote } from "@/hooks/data/use-quotes"
import { useScaleSettings } from "@/hooks/data/use-scale-settings"
import type { ScanFeedback } from "@/hooks/use-barcode-scanner"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import {
  addManualLineToCart,
  applyScanToCart,
  calcCartTotal,
  removeLine,
  unitPriceFromSubtotal,
  updateLineQuantity,
  updateLineSubtotal,
  type SaleCartItem,
  type StagedCartLine,
} from "@/lib/cart-utils"
import { argentinaToday } from "@/lib/date-range"
import { formatMoney } from "@/lib/format"
import { humanizeOperationError } from "@/lib/operation-errors"
import { normalizeWhatsAppPhone } from "@/lib/phone-utils"
import { queryKeys } from "@/lib/query-keys"
import {
  defaultQuoteValidUntil,
  QUOTE_NOTES_MAX,
  rehydrateQuoteLines,
  validateQuoteDraft,
  type RehydratedQuote,
} from "@/lib/quote-form"
import {
  addServiceLine,
  buildQuoteItemsPayload,
  removeServiceLine,
  SERVICE_DESCRIPTION_MAX,
  updateServiceLine,
  validateServiceLineInput,
  type QuoteServiceLine,
} from "@/lib/quote-lines"
import type { QuoteApiRow } from "@/lib/quote-types"
import { resolveScan } from "@/lib/scan-resolution"
import { unitInputMin, unitInputStep, resolveUnit } from "@/lib/unit-utils"
import type { Client } from "@/lib/types"

const DEFAULT_VALIDITY_DAYS = 15
const STOCK_NOTICE_SUFFIX = "El presupuesto no reserva stock: se puede cotizar igual."

export interface QuoteFormProps {
  /** Edita este presupuesto (reemplazo completo, con su `revision`). */
  quote?: QuoteApiRow
  /** Precarga cliente, notas y líneas desde este presupuesto (duplicado). */
  duplicateFrom?: QuoteApiRow
  /** Cliente preseleccionado (`?cliente=`). */
  initialClientId?: string
  /** Qué hacer con "Recargar" ante `quote_changed`; por defecto invalida el detalle. */
  onReload?: () => void
}

const EMPTY_LINES: RehydratedQuote = {
  cartItems: [],
  serviceLines: [],
  loadOrder: [],
  unavailableIds: [],
  priceChanges: [],
}

const STATUS_WORD: Record<string, string> = { expired: "vencido", rejected: "rechazado" }

export function QuoteForm({ quote, duplicateFrom, initialClientId, onReload }: QuoteFormProps) {
  const router = useRouter()
  const queryClient = useQueryClient()
  const uid = useId()
  const { products } = useProducts()
  const { clients } = useClients()
  const { units, unitsById } = useUnitsOfMeasure()
  const { settings: scaleSettings } = useScaleSettings()
  const { data: quoteSettings } = useQuoteSettings()
  const createQuote = useCreateQuote()
  const updateQuote = useUpdateQuote()

  const isEdit = !!quote
  const today = argentinaToday()
  const defaultValidUntil = defaultQuoteValidUntil(
    today,
    quoteSettings?.defaultQuoteValidityDays ?? DEFAULT_VALIDITY_DAYS,
  )

  // Un vencido (marcado o todavía no marcado por el barrido) o un rechazado:
  // la edición lo reabre y la validez vieja no sirve.
  const reopens = !!quote && (quote.status === "expired" || quote.status === "rejected")
  const overdueOpen = !!quote && quote.is_expired && !reopens
  const needsFreshValidity = reopens || overdueOpen

  const source = quote ?? duplicateFrom
  const productById = useMemo(() => new Map(products.map((p) => [p.id, p])), [products])

  // ── Estado inicial: una sola rehidratación, al montar ────────────────────────
  const initial = useMemo<RehydratedQuote>(
    () =>
      source
        ? rehydrateQuoteLines(source.items, { unitsById, products }, quote ? "edit" : "duplicate")
        : EMPTY_LINES,
    // Se calcula UNA vez: el estado del formulario es del usuario desde ahí.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [],
  )
  const [cartItems, setCartItems] = useState<SaleCartItem[]>(initial.cartItems)
  const [serviceLines, setServiceLines] = useState<QuoteServiceLine[]>(initial.serviceLines)
  const [loadOrder, setLoadOrder] = useState<string[]>(initial.loadOrder)
  const [unavailableIds, setUnavailableIds] = useState<string[]>(initial.unavailableIds)
  const priceChanges = initial.priceChanges

  const [clientId, setClientId] = useState<string>(source?.client_id ?? initialClientId ?? "")
  const [createdClient, setCreatedClient] = useState<Client | null>(null)
  const [showNewClient, setShowNewClient] = useState(false)
  const [branchId, setBranchId] = useState<string | null>(source?.branch_id ?? null)
  const [validUntil, setValidUntil] = useState<string>(() =>
    quote && !needsFreshValidity && quote.valid_until ? quote.valid_until : "",
  )
  const [validUntilTouched, setValidUntilTouched] = useState(!!quote && !needsFreshValidity)
  const [notes, setNotes] = useState<string>(source?.notes ?? "")
  const [stockNotice, setStockNotice] = useState<string | null>(null)
  const [conflict, setConflict] = useState(false)
  const [submitting, setSubmitting] = useState(false)
  const submittingRef = useRef(false)

  // Concepto en preparación (línea de servicio).
  const [serviceDescription, setServiceDescription] = useState("")
  const [serviceQuantity, setServiceQuantity] = useState(1)
  const [servicePrice, setServicePrice] = useState(0)

  const stagedRef = useRef<StagedProductLineHandle>(null)
  const formRef = useRef<HTMLFormElement>(null)

  // La validez muestra el default de la cuenta hasta que el usuario la toca.
  const effectiveValidUntil = validUntilTouched ? validUntil : validUntil || defaultValidUntil

  // ── Cliente ──────────────────────────────────────────────────────────────────
  const clientOptions = useMemo(() => {
    const options = clients.map((c) => ({ value: c.id, label: c.name }))
    const extras: { value: string; label: string }[] = []
    if (createdClient && !options.some((o) => o.value === createdClient.id)) {
      extras.push({ value: createdClient.id, label: createdClient.name })
    }
    if (source?.client_id && source.client_name && !options.some((o) => o.value === source.client_id)) {
      extras.push({ value: source.client_id, label: source.client_name })
    }
    return [...extras, ...options]
  }, [clients, createdClient, source?.client_id, source?.client_name])

  const selectedClientPhone = useMemo<string | null>(() => {
    if (!clientId) return null
    const known = clients.find((c) => c.id === clientId) ?? (createdClient?.id === clientId ? createdClient : null)
    if (known) return known.phone || null
    return source?.client_id === clientId ? (source.client_phone ?? null) : null
  }, [clientId, clients, createdClient, source])
  const hasClientPhone = !!normalizeWhatsAppPhone(selectedClientPhone)

  // ── Carrito ──────────────────────────────────────────────────────────────────
  const total = useMemo(() => calcCartTotal([...cartItems, ...serviceLines]), [cartItems, serviceLines])

  const noteNewIds = useCallback((ids: string[]) => {
    setLoadOrder((prev) => {
      const known = new Set(prev)
      return [...prev, ...ids.filter((id) => !known.has(id))]
    })
  }, [])

  const commitCart = useCallback(
    (items: SaleCartItem[]) => {
      setCartItems(items)
      noteNewIds(items.map((i) => i.id))
    },
    [noteNewIds],
  )

  const cartCtx = useMemo(() => ({ unitsById, products }), [unitsById, products])

  function stockNoticeFrom(warning?: string): void {
    setStockNotice(warning ? `${warning}. ${STOCK_NOTICE_SUFFIX}` : null)
  }

  function handleAddStaged(staged: StagedCartLine): boolean {
    const result = addManualLineToCart(cartItems, staged, cartCtx, { enforceStock: false })
    if (!result.ok) {
      toast.error(result.message)
      return false
    }
    commitCart(result.items)
    stockNoticeFrom(result.stockWarning)
    toast.success(result.merged ? `Cantidad actualizada: ${result.productName}` : `${result.productName} agregado`)
    return true
  }

  function handleScan(code: string): ScanFeedback {
    const scan = resolveScan(code, { products, units, unitsById, settings: scaleSettings })
    const result = applyScanToCart(cartItems, scan, cartCtx, { enforceStock: false })
    if (result.kind === "rejected") return { ok: false, label: result.label }
    if (result.kind === "needs_quantity") {
      // Producto medible por código común/SKU: queda elegido con el foco en la cantidad.
      stagedRef.current?.selectProduct(result.product.id)
      return { ok: true, label: result.label }
    }
    commitCart(result.items)
    stockNoticeFrom(result.stockWarning)
    return { ok: true, label: result.label }
  }

  function handleRemove(id: string) {
    setCartItems((prev) => removeLine(prev, id))
    setServiceLines((prev) => removeServiceLine(prev, id))
    setLoadOrder((prev) => prev.filter((x) => x !== id))
    setUnavailableIds((prev) => prev.filter((x) => x !== id))
  }

  function handleUpdateQty(id: string, quantity: number) {
    setCartItems((prev) => updateLineQuantity(prev, id, quantity, cartCtx))
    setServiceLines((prev) => updateServiceLine(prev, id, { quantity }))
  }

  function handleUpdateSubtotal(id: string, subtotal: number) {
    setCartItems((prev) => updateLineSubtotal(prev, id, subtotal))
    setServiceLines((prev) => {
      const line = prev.find((l) => l.id === id)
      return line ? updateServiceLine(prev, id, { unitPrice: unitPriceFromSubtotal(subtotal, line.quantity) }) : prev
    })
  }

  function handleAddService() {
    const input = { description: serviceDescription, quantity: serviceQuantity, unitPrice: servicePrice }
    const problem = validateServiceLineInput(input)
    if (problem) {
      toast.error(problem)
      return
    }
    const next = addServiceLine(serviceLines, input)
    setServiceLines(next)
    noteNewIds([next[next.length - 1].id])
    setServiceDescription("")
    setServiceQuantity(1)
    setServicePrice(0)
  }

  // ── Lista unificada, en el orden en que se cargó ─────────────────────────────
  const displayItems = useMemo<CartDisplayItem[]>(() => {
    const cartById = new Map(cartItems.map((i) => [i.id, i]))
    const serviceById = new Map(serviceLines.map((l) => [l.id, l]))
    const unavailable = new Set(unavailableIds)
    const orderedIds = [
      ...loadOrder.filter((id) => cartById.has(id) || serviceById.has(id)),
      ...[...cartById.keys(), ...serviceById.keys()].filter((id) => !loadOrder.includes(id)),
    ]
    return orderedIds.map((id): CartDisplayItem => {
      const line = cartById.get(id)
      if (line) {
        const lineUnit = resolveUnit(line.unitId, unitsById)
        return {
          id: line.id,
          productName: line.productName,
          quantity: line.quantity,
          unitValue: line.unitPrice,
          subtotal: line.subtotal,
          step: line.step ?? unitInputStep(lineUnit),
          minQty: line.minQty ?? unitInputMin(lineUnit),
          badge:
            [
              unavailable.has(line.id) ? "Producto no disponible" : null,
              line.unitSymbol ?? lineUnit?.symbol ?? null,
              line.discount > 0 ? `${line.discount}% desc.` : null,
            ]
              .filter(Boolean)
              .join(" · ") || undefined,
        }
      }
      const service = serviceById.get(id) as QuoteServiceLine
      return {
        id: service.id,
        productName: service.description,
        quantity: service.quantity,
        unitValue: service.unitPrice,
        subtotal: service.subtotal,
        step: 1,
        minQty: 0.001,
        badge: "Concepto",
      }
    })
  }, [cartItems, serviceLines, loadOrder, unavailableIds, unitsById])

  // ── Envío ────────────────────────────────────────────────────────────────────
  async function handleSubmit(event: React.FormEvent) {
    event.preventDefault()
    if (submittingRef.current) return

    const problem = validateQuoteDraft({
      clientId,
      itemCount: cartItems.length + serviceLines.length,
      validUntil: effectiveValidUntil,
      today,
      notes,
      unavailableCount: unavailableIds.length,
    })
    if (problem) {
      toast.error(problem)
      return
    }

    submittingRef.current = true
    setSubmitting(true)
    setConflict(false)
    const items = buildQuoteItemsPayload({ cartItems, serviceLines, loadOrder })
    const trimmedNotes = notes.trim() || null
    try {
      if (isEdit && quote) {
        await updateQuote.mutateAsync({
          quoteId: quote.id,
          payload: {
            client_id: clientId,
            branch_id: branchId,
            valid_until: effectiveValidUntil,
            notes: trimmedNotes,
            revision: quote.revision,
            items,
          },
        })
        toast.success("Presupuesto actualizado")
        router.push(`/presupuestos/${quote.id}`)
        return
      }
      const created = await createQuote.mutateAsync({
        client_id: clientId,
        branch_id: branchId,
        valid_until: effectiveValidUntil,
        notes: trimmedNotes,
        items,
      })
      toast.success("Presupuesto creado")
      router.push(`/presupuestos/${created.id}`)
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : ""
      if (/quote_changed/.test(message)) {
        setConflict(true)
        return
      }
      const lookupName = (productId: string) => cartItems.find((i) => i.productId === productId)?.productName
      toast.error(humanizeOperationError(message, lookupName).message)
    } finally {
      submittingRef.current = false
      setSubmitting(false)
    }
  }

  function handleReload() {
    if (onReload) {
      onReload()
      return
    }
    if (quote) queryClient.invalidateQueries({ queryKey: queryKeys.quotes.detail(quote.id) })
  }

  const itemCount = cartItems.length + serviceLines.length
  const validUntilId = `${uid}-valid-until`
  const notesId = `${uid}-notes`
  const submitLabel = submitting
    ? "Guardando…"
    : isEdit
      ? "Guardar cambios"
      : itemCount > 1
        ? `Crear presupuesto (${itemCount} ítems)`
        : "Crear presupuesto"

  return (
    <>
    <form ref={formRef} onSubmit={handleSubmit} className="flex flex-col gap-4" noValidate>
      {conflict && (
        <div
          role="alert"
          className="flex flex-col gap-2 rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground sm:flex-row sm:items-center sm:justify-between"
        >
          <p className="flex items-start gap-2">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0 text-warning" aria-hidden="true" />
            <span>
              Otro usuario modificó este presupuesto mientras lo editabas. Recargalo para ver cómo quedó y volvé a
              aplicar tus cambios: no pisamos lo que cambió.
            </span>
          </p>
          <Button type="button" size="sm" variant="outline" onClick={handleReload} className="gap-1.5 shrink-0">
            <RefreshCw className="h-3.5 w-3.5" aria-hidden="true" />
            Recargar presupuesto
          </Button>
        </div>
      )}

      {reopens && quote && (
        <p
          role="status"
          aria-label="Se reabre como borrador"
          className="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
        >
          Este presupuesto está {STATUS_WORD[quote.status]}. Al guardar los cambios se reabre como borrador: ampliá la
          validez (hoy o una fecha posterior) antes de reenviarlo.
        </p>
      )}

      {overdueOpen && (
        <p
          role="status"
          aria-label="Presupuesto vencido"
          className="rounded-lg border border-warning/40 bg-warning/10 px-4 py-3 text-sm text-foreground"
        >
          Este presupuesto está vencido. Ampliá la validez (hoy o una fecha posterior) para poder enviarlo o
          convertirlo en venta.
        </p>
      )}

      {duplicateFrom && priceChanges.length > 0 && (
        <div
          role="status"
          aria-label="Precios actualizados"
          className="rounded-lg border border-border bg-accent/40 px-4 py-3 text-sm text-foreground"
        >
          <p className="font-medium">Actualizamos los precios a los de hoy</p>
          <ul className="mt-1 list-disc pl-5 text-muted-foreground">
            {priceChanges.map((change) => (
              <li key={`${change.name}-${change.previous}`}>
                {change.name}: {formatMoney(change.previous)} → {formatMoney(change.current)}
              </li>
            ))}
          </ul>
          <p className="mt-1 text-muted-foreground">Los descuentos no se copian: aplicalos de nuevo si corresponde.</p>
        </div>
      )}

      <ScrollableCartShell
        className="sm:max-h-[calc(100dvh-12rem)]"
        hasItems={displayItems.length > 0}
        listContent={
          <CartItemList
            items={displayItems}
            onRemove={handleRemove}
            onUpdateQty={handleUpdateQty}
            onUpdateSubtotal={handleUpdateSubtotal}
            unitLabel="Precio unit."
            currency="ARS"
          />
        }
        footerContent={
          <>
            {stockNotice && (
              <p
                role="status"
                aria-label="Aviso de stock"
                className="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-xs text-foreground"
              >
                {stockNotice}
              </p>
            )}
            {unavailableIds.length > 0 && (
              <p
                role="status"
                aria-label="Productos no disponibles"
                className="rounded-lg border border-destructive/30 bg-destructive/10 px-3 py-2 text-xs text-destructive"
              >
                Hay productos que ya no están en el catálogo: quitalos o reemplazalos para poder guardar.
              </p>
            )}
            {itemCount > 0 && (
              <div className="rounded-lg border border-border bg-accent/50 p-3">
                <div className="flex items-center justify-between">
                  <span className="flex items-center gap-2 text-sm text-muted-foreground">
                    <ShoppingCart className="h-4 w-4" aria-hidden="true" />
                    Total — {itemCount} ítem{itemCount !== 1 ? "s" : ""}
                  </span>
                  <span className="text-xl font-bold text-primary tabular-nums">{formatMoney(total)}</span>
                </div>
              </div>
            )}
            <Button type="submit" className="w-full" disabled={submitting}>
              {submitLabel}
            </Button>
          </>
        }
      >
        {/* ── Cabecera: cliente, sucursal, validez y notas ───────────────────── */}
        <div className="flex flex-col gap-3">
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between gap-2">
              <Label className="text-foreground" id={`${uid}-client-label`}>
                Cliente
              </Label>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="h-6 text-xs text-primary"
                onClick={() => setShowNewClient(true)}
              >
                <UserPlus className="mr-1 h-3 w-3" aria-hidden="true" />
                Nuevo cliente
              </Button>
            </div>
            <SearchableSelect
              options={clientOptions}
              value={clientId}
              onValueChange={setClientId}
              placeholder="Elegí un cliente"
              searchPlaceholder="Buscar cliente..."
              emptyMessage="No se encontraron clientes."
              aria-labelledby={`${uid}-client-label`}
            />
            {clientId && (
              <p role="status" aria-live="polite" className="text-xs text-muted-foreground">
                {hasClientPhone
                  ? `WhatsApp: ${selectedClientPhone}`
                  : "Sin teléfono: WhatsApp va a abrir el selector de contactos para elegir a quién mandarlo."}
              </p>
            )}
          </div>

          <BranchSelect
            value={branchId}
            onChange={setBranchId}
            placeholder="Sin sucursal (general)"
            className="bg-background border-border text-foreground text-sm"
          />

          <div className="grid grid-cols-1 gap-3 sm:grid-cols-2">
            <div className="flex flex-col gap-2">
              <Label htmlFor={validUntilId} className="text-foreground">
                Válido hasta
              </Label>
              <input
                id={validUntilId}
                type="date"
                value={effectiveValidUntil}
                min={today}
                onChange={(e) => {
                  setValidUntil(e.target.value)
                  setValidUntilTouched(true)
                }}
                className="flex h-10 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
              />
            </div>
          </div>

          <div className="flex flex-col gap-2">
            <Label htmlFor={notesId} className="text-foreground">
              Notas y condiciones
              <span className="ml-2 text-xs font-normal text-muted-foreground tabular-nums">
                {notes.length}/{QUOTE_NOTES_MAX}
              </span>
            </Label>
            <Textarea
              id={notesId}
              value={notes}
              onChange={(e) => setNotes(e.target.value)}
              placeholder="Forma de entrega, condiciones de pago, aclaraciones…"
              rows={2}
              className="min-h-[60px] bg-background border-border text-foreground"
            />
          </div>
        </div>

        <div className="border-t border-border" />

        {/* ── Producto ────────────────────────────────────────────────────────── */}
        <StagedProductLine
          ref={stagedRef}
          products={products}
          productById={productById}
          units={units}
          unitsById={unitsById}
          currency="ARS"
          onAdd={handleAddStaged}
          addLabel="Agregar al presupuesto"
          headerSlot={<BarcodeScannerInput onScan={handleScan} scopeRef={formRef} guardFocusedInput />}
        />

        {/* ── Concepto (línea de servicio, sin producto) ──────────────────────── */}
        <div
          role="group"
          aria-label="Agregar concepto"
          className="flex flex-col gap-2 rounded-lg border border-dashed border-border bg-accent/15 p-3"
        >
          <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
            Agregar concepto (sin producto)
          </p>
          <Input
            aria-label="Concepto: descripción"
            value={serviceDescription}
            maxLength={SERVICE_DESCRIPTION_MAX}
            onChange={(e) => setServiceDescription(e.target.value)}
            placeholder="Ej: Flete, mano de obra, instalación"
            className="bg-background border-border text-foreground text-sm"
          />
          <div className="grid grid-cols-2 gap-2">
            <NumericInput
              aria-label="Concepto: cantidad"
              min={0.001}
              step={1}
              value={serviceQuantity}
              onValueChange={setServiceQuantity}
              className="bg-background border-border text-foreground"
            />
            <NumericInput
              aria-label="Concepto: precio"
              min={0}
              step={1}
              value={servicePrice}
              onValueChange={setServicePrice}
              className="bg-background border-border text-foreground"
            />
          </div>
          <Button type="button" variant="secondary" onClick={handleAddService} className="w-full gap-2">
            <Plus className="h-4 w-4" aria-hidden="true" />
            Agregar concepto
          </Button>
        </div>
      </ScrollableCartShell>
    </form>

    {/* Fuera del <form>: el modal se portaliza, pero los eventos de React suben
        por el árbol de componentes y el submit del alta de cliente dispararía
        también el guardado del presupuesto. */}
    <ResponsiveModal open={showNewClient} onOpenChange={setShowNewClient} title="Nuevo cliente">
      <ClientForm
        onSuccess={(client) => {
          setShowNewClient(false)
          if (client) {
            setCreatedClient(client)
            setClientId(client.id)
          }
        }}
      />
    </ResponsiveModal>
    </>
  )
}
