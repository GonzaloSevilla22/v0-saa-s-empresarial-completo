"use client"

/**
 * C-29 v21-quote-salesorder — POS quickSale screen.
 *
 * Fast mostrador flow: pick products → build cart → choose payment
 * method → resolve cash session (if cash) → submit via useQuickSale.
 *
 * Mirrors the Ventas page for auth guard + NoWriteAccessBanner.
 * Reuses: ProductPicker, CartItemList, ScrollableCartShell, SearchableSelect.
 *
 * Cash session integration:
 *   - Fetches branches → first branch → cashboxes → first cashbox → currentSession.
 *   - For cash payment, blocks submit if no open session and shows a link to /sucursales.
 *   - For 'other' payment, no session needed (cash_session_id omitted).
 */

import { useState, useMemo, useRef, useCallback, useEffect } from "react"
import Link from "next/link"
import { ShoppingCart, PackagePlus, Plus, AlertCircle, CheckCircle2, FileText, ExternalLink } from "lucide-react"
import { toast } from "sonner"

import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { NumericInput } from "@/components/ui/numeric-input"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { CartItemList } from "@/components/shared/cart-item-list"
import { ScrollableCartShell } from "@/components/shared/scrollable-cart-shell"
import { ProductPicker } from "@/components/shared/product-picker"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"
import { FiscalDocumentBadge, type FiscalDocumentStatus } from "@/components/fiscal/FiscalDocumentBadge"

import { useOrgRole } from "@/hooks/useOrgRole"
import { useProducts } from "@/hooks/data/use-products"
import { useClients } from "@/hooks/data/use-clients"
import { useBranches } from "@/hooks/data/use-branches"
import { useCashboxes } from "@/hooks/data/use-cashboxes"
import { useCurrentSession } from "@/hooks/data/use-cash-session"
import { useQuickSale, type QuickSaleInput, type PaymentMethod } from "@/hooks/data/use-sales-orders"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { useFiscalProfile } from "@/hooks/data/use-fiscal-profile"
import { usePointsOfSale } from "@/hooks/data/use-points-of-sale"

import { formatMoney } from "@/lib/format"
import {
  calcSaleSubtotal,
  calcCartTotal,
  unitPriceFromSubtotal,
  type SaleCartItem,
} from "@/lib/cart-utils"
import {
  unitInputStep,
  unitInputMin,
  toBaseQuantity,
  resolveUnit,
} from "@/lib/unit-utils"
import { getCanonicalLabel } from "@/lib/product-labels"

// ── Error code → friendly Spanish messages ────────────────────────────────────

function friendlyError(message: string): string {
  if (message.includes("stock_insuficiente") || message.toLowerCase().includes("stock insuficiente"))
    return "Stock insuficiente para completar la venta."
  if (message.includes("no_open_session") || message.toLowerCase().includes("caja abierta"))
    return "No hay caja abierta en esta sucursal. Abrí una sesión de caja antes de cobrar en efectivo."
  if (message.includes("cash_requires_session"))
    return "Ingresá la sesión de caja para cobrar en efectivo."
  if (message.includes("branch_closed") || message.toLowerCase().includes("sucursal"))
    return "La sucursal está cerrada. Abrila antes de operar."
  if (message.includes("unauthorized") || message.toLowerCase().includes("permiso"))
    return "Sin permiso de escritura para esta operación."
  if (message.includes("no_branch_found"))
    return "No se encontró sucursal activa para la cuenta."
  if (message.includes("no_active_point_of_sale"))
    return "La cuenta no tiene puntos de venta activos. Configurá uno en Perfil Fiscal."
  if (message.includes("ambiguous_point_of_sale"))
    return "La cuenta tiene varios puntos de venta activos. Seleccioná cuál usar."
  return message || "Ocurrió un error inesperado."
}

// ── Last-sale summary state ───────────────────────────────────────────────────

interface LastSaleResult {
  salesOrderId: string
  total: number
  // v22: fiscal document if emission was requested
  fiscalDocumentId: string | null
  fiscalDocumentStatus: FiscalDocumentStatus | null
}

// ── Component ─────────────────────────────────────────────────────────────────

export default function PosPage() {
  // ── Auth & role ─────────────────────────────────────────────────────────────
  const { isWriter } = useOrgRole()

  // ── Catalog data ─────────────────────────────────────────────────────────────
  const { products }             = useProducts()
  const { clients }              = useClients()
  const { units, unitsById }     = useUnitsOfMeasure()

  // ── Branch / cash session resolution ─────────────────────────────────────────
  // Use the first active branch to resolve the cashbox. The backend also resolves
  // the default branch (c26_default_branch) if branch_id is omitted, so we only
  // need the branch to look up the cashbox → session for cash payments.
  const { branches }             = useBranches()
  const activeBranch             = branches[0] ?? null

  const { data: cashboxes }      = useCashboxes(activeBranch?.id ?? null)
  const firstCashbox             = cashboxes?.[0] ?? null

  const { data: currentSession, isLoading: sessionLoading } =
    useCurrentSession(firstCashbox?.id ?? null)

  // ── Cart state ───────────────────────────────────────────────────────────────
  const [cartItems, setCartItems] = useState<SaleCartItem[]>([])

  // ── Staged item (product adder section) ──────────────────────────────────────
  const [productId,   setProductId]   = useState("")
  const [unitPrice,   setUnitPrice]   = useState(0)
  const [quantity,    setQuantity]    = useState(1)
  const [unitId,      setUnitId]      = useState("")

  // Editable subtotal for the staged item (back-computes unit price)
  const [subtotalFocused, setSubtotalFocused] = useState(false)
  const [subtotalDraft,   setSubtotalDraft]   = useState(0)

  // ── Header fields ─────────────────────────────────────────────────────────────
  const [clientId,       setClientId]       = useState("")
  const [paymentMethod,  setPaymentMethod]  = useState<PaymentMethod>("cash")

  // ── Submission state ──────────────────────────────────────────────────────────
  const [submitting,  setSubmitting]  = useState(false)
  const submittingRef                  = useRef(false)
  const [lastSale,    setLastSale]    = useState<LastSaleResult | null>(null)

  // ── Idempotency key (per-tab, stable across F5) ───────────────────────────────
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey("pos-quick-sale")

  // ── Mutation ──────────────────────────────────────────────────────────────────
  const quickSale = useQuickSale()

  // ── v22: Fiscal emission (opt-in) ─────────────────────────────────────────────
  // The user checks "Emitir comprobante" to include comprobante_type + point_of_sale_id
  // in the quickSale payload. Emission is NEVER automatic.
  const { profile: fiscalProfile } = useFiscalProfile()
  const { pointsOfSale }           = usePointsOfSale()

  const activePVs = useMemo(
    () => pointsOfSale.filter((pv) => pv.isActive),
    [pointsOfSale],
  )

  const [emitirComprobante, setEmitirComprobante] = useState(false)
  const [selectedPvId,      setSelectedPvId]      = useState<string>("")

  // Auto-select PV when there is exactly one active
  useEffect(() => {
    if (activePVs.length === 1 && !selectedPvId) {
      setSelectedPvId(activePVs[0].id)
    }
  }, [activePVs, selectedPvId])

  const canEmit =
    emitirComprobante &&
    fiscalProfile !== null &&
    fiscalProfile.delegacionAutorizada &&
    activePVs.length > 0 &&
    selectedPvId !== ""

  // ── Derived: product maps ─────────────────────────────────────────────────────
  const parentProductIds = useMemo(() => {
    const ids = new Set<string>()
    for (const p of products) if (p.parentId) ids.add(p.parentId)
    return ids
  }, [products])

  const productById = useMemo(
    () => new Map(products.map((p) => [p.id, p])),
    [products],
  )

  const selectedProduct = useMemo(
    () => products.find((p) => p.id === productId),
    [products, productId],
  )

  const selectedUnit = useMemo(
    () => resolveUnit(unitId, unitsById),
    [unitId, unitsById],
  )

  const stagedStep = useMemo(() => unitInputStep(selectedUnit), [selectedUnit])
  const stagedMin  = useMemo(() => unitInputMin(selectedUnit),  [selectedUnit])

  const stagedSubtotal = useMemo(
    () => (selectedProduct ? calcSaleSubtotal(unitPrice, quantity, 0) : 0),
    [selectedProduct, unitPrice, quantity],
  )

  const stagedQuantityNormalized = useMemo(
    () => toBaseQuantity(quantity, selectedUnit),
    [quantity, selectedUnit],
  )

  const cartTotal = useMemo(() => calcCartTotal(cartItems), [cartItems])

  const clientOptions = useMemo(
    () => clients.map((c) => ({ value: c.id, label: c.name })),
    [clients],
  )

  // ── Cash session validation ───────────────────────────────────────────────────
  // For cash payments: we need an open session. If none, block and show a link.
  const cashSessionMissing =
    paymentMethod === "cash" &&
    !sessionLoading &&
    firstCashbox !== null &&
    !currentSession

  const noCashboxForBranch =
    paymentMethod === "cash" &&
    !sessionLoading &&
    activeBranch !== null &&
    !firstCashbox

  // ── Handlers ─────────────────────────────────────────────────────────────────

  function handleProductChange(id: string) {
    setProductId(id)
    setQuantity(1)
    setUnitId("")
    const p = products.find((x) => x.id === id)
    setUnitPrice(p?.price ?? 0)
  }

  function handleAddToCart() {
    if (!selectedProduct) {
      toast.error("Seleccioná un producto")
      return
    }

    const existing = cartItems.find(
      (item) => item.productId === productId && (item.unitId ?? "") === unitId,
    )

    if (existing) {
      const newQty        = existing.quantity + quantity
      const newNormalized = toBaseQuantity(newQty, selectedUnit)
      if (newNormalized > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${selectedProduct.stock})`)
        return
      }
      setCartItems((prev) =>
        prev.map((item) =>
          item.id === existing.id
            ? {
                ...item,
                quantity:     newQty,
                quantityBase: newNormalized,
                subtotal:     calcSaleSubtotal(item.unitPrice, newQty, 0),
              }
            : item,
        ),
      )
      toast.success(`Cantidad actualizada: ${selectedProduct.name}`)
    } else {
      if (stagedQuantityNormalized > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${selectedProduct.stock})`)
        return
      }
      const parent = selectedProduct.parentId
        ? productById.get(selectedProduct.parentId)
        : undefined
      setCartItems((prev) => [
        ...prev,
        {
          id:           crypto.randomUUID(),
          productId:    selectedProduct.id,
          productName:  getCanonicalLabel(selectedProduct, parent),
          unitPrice,
          quantity,
          discount:     0,
          subtotal:     stagedSubtotal,
          unitId:       unitId || undefined,
          unitSymbol:   selectedUnit?.symbol,
          unitFactor:   selectedUnit?.factor,
          quantityBase: stagedQuantityNormalized,
          step:         stagedStep,
          minQty:       stagedMin,
        },
      ])
      toast.success(`${selectedProduct.name} agregado`)
    }

    // Reset staged item
    setProductId("")
    setUnitPrice(0)
    setQuantity(1)
    setUnitId("")
  }

  function handleRemoveItem(id: string) {
    setCartItems((prev) => prev.filter((item) => item.id !== id))
  }

  function handleUpdateQty(id: string, qty: number) {
    setCartItems((prev) =>
      prev.map((item) => {
        if (item.id !== id) return item
        const newQty = Math.max(item.minQty ?? 1, qty)
        return {
          ...item,
          quantity:     newQty,
          quantityBase: toBaseQuantity(newQty, resolveUnit(item.unitId, unitsById)),
          subtotal:     calcSaleSubtotal(item.unitPrice, newQty, 0),
        }
      }),
    )
  }

  function handleUpdateSubtotal(id: string, newSubtotal: number) {
    setCartItems((prev) =>
      prev.map((item) =>
        item.id === id
          ? {
              ...item,
              unitPrice: unitPriceFromSubtotal(newSubtotal, item.quantity),
              discount:  0,
              subtotal:  newSubtotal,
            }
          : item,
      ),
    )
  }

  const handleClearCart = useCallback(() => {
    setCartItems([])
    setClientId("")
    setProductId("")
    setUnitPrice(0)
    setQuantity(1)
    setUnitId("")
    setLastSale(null)
    // v22: reset fiscal emission opt-in (keep PV selection for convenience)
    setEmitirComprobante(false)
  }, [])

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()

    if (!isWriter) {
      toast.error("Sin permiso de escritura.")
      return
    }
    if (cartItems.length === 0) {
      toast.error("Agregá al menos un producto al carrito")
      return
    }
    if (submittingRef.current) return
    submittingRef.current = true

    // Cash payment without open session → block
    if (paymentMethod === "cash" && !currentSession) {
      toast.error("No hay caja abierta. Abrí una sesión de caja antes de cobrar en efectivo.")
      submittingRef.current = false
      return
    }

    setSubmitting(true)
    setLastSale(null)

    const payload: QuickSaleInput = {
      idempotency_key:   idempotencyKey,
      client_id:         clientId || null,
      payment_method:    paymentMethod,
      cash_session_id:   paymentMethod === "cash" ? (currentSession?.id ?? null) : null,
      branch_id:         activeBranch?.id ?? null,
      // v22: emisión opt-in — solo se pasa si el usuario activó la opción
      ...(canEmit && {
        comprobante_type: "factura_c",  // backend resuelve el tipo real por condición IVA
        point_of_sale_id: selectedPvId,
      }),
      items: cartItems.map((item) => ({
        product_id: item.productId,
        unit_id:    item.unitId ?? null,
        quantity:   item.quantity,
        price:      item.unitPrice,
        subtotal:   item.subtotal,
      })),
    }

    try {
      const result = await quickSale.mutateAsync(payload)
      resetIdempotencyKey()
      setLastSale({
        salesOrderId:          result.sales_order_id,
        total:                 Number(result.total),
        // v22: fiscal_doc_id comes back when emission was requested
        fiscalDocumentId:      result.fiscal_doc_id ?? null,
        fiscalDocumentStatus:  result.fiscal_doc_id ? "pending_cae" : null,
      })
      setCartItems([])
      setClientId("")
      const fiscalNote = canEmit ? " — Comprobante enviado a ARCA" : ""
      toast.success(
        cartItems.length > 1
          ? `Venta registrada (${cartItems.length} ítems) — $${Number(result.total).toLocaleString("es-AR")}${fiscalNote}`
          : `Venta registrada correctamente${fiscalNote}`,
      )
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : "Error inesperado"
      toast.error(friendlyError(msg))
    } finally {
      setSubmitting(false)
      submittingRef.current = false
    }
  }

  // ── Render ────────────────────────────────────────────────────────────────────

  return (
    <div className="flex flex-col gap-6 max-w-2xl mx-auto">
      {/* Page header */}
      <div className="flex items-start justify-between gap-4">
        <div>
          <h1 className="text-2xl font-bold text-foreground tracking-tight">
            POS — Venta Rápida
          </h1>
          <p className="text-sm text-muted-foreground mt-1">
            Cobrá en el mostrador sin intermedios. Cada venta es atómica e idempotente.
          </p>
        </div>
        <Button asChild variant="outline" size="sm">
          <Link href="/ventas">Ver ventas</Link>
        </Button>
      </div>

      {/* Write access guard */}
      {!isWriter && <NoWriteAccessBanner />}

      {/* Last-sale success card */}
      {lastSale && (
        <div className="flex items-start gap-3 rounded-lg border border-green-500/30 bg-green-500/10 px-4 py-3 text-sm text-green-700 dark:text-green-400">
          <CheckCircle2 className="h-4 w-4 mt-0.5 shrink-0" />
          <div className="flex flex-col gap-0.5">
            <span className="font-semibold">
              Venta confirmada — {formatMoney(lastSale.total, "ARS")}
            </span>
            <span className="text-xs text-green-600/70 dark:text-green-500/70 font-mono">
              {lastSale.salesOrderId.slice(0, 8)}…
            </span>
            {/* v22: fiscal document badge if emission was requested */}
            {lastSale.fiscalDocumentId && lastSale.fiscalDocumentStatus && (
              <div className="mt-1">
                <FiscalDocumentBadge
                  documentId={lastSale.fiscalDocumentId}
                  initialStatus={lastSale.fiscalDocumentStatus}
                  verbose
                />
              </div>
            )}
          </div>
          <Button
            size="sm"
            variant="ghost"
            className="ml-auto h-6 text-xs text-green-700 dark:text-green-400"
            onClick={handleClearCart}
          >
            Nueva venta
          </Button>
        </div>
      )}

      {/* Cash session warning */}
      {(cashSessionMissing || noCashboxForBranch) && paymentMethod === "cash" && (
        <div className="flex items-start gap-3 rounded-lg border border-amber-500/30 bg-amber-500/10 px-4 py-3 text-sm text-amber-700 dark:text-amber-400">
          <AlertCircle className="h-4 w-4 mt-0.5 shrink-0" />
          <div className="flex flex-col gap-1">
            <span className="font-medium">
              {noCashboxForBranch
                ? "Esta sucursal no tiene una caja configurada."
                : "No hay caja abierta en esta sucursal."}
            </span>
            <span className="text-xs">
              {noCashboxForBranch
                ? "Creá una caja para poder cobrar en efectivo."
                : "Abrí una sesión de caja antes de cobrar en efectivo, o cambiá el método de pago a 'Otro'."}
            </span>
            {activeBranch && (
              <Link
                href={`/sucursales/${activeBranch.id}/caja`}
                className="text-xs underline underline-offset-2 text-amber-600 dark:text-amber-400 hover:text-amber-500 transition-colors"
              >
                Ir a caja de {activeBranch.name} →
              </Link>
            )}
          </div>
        </div>
      )}

      {/* Main POS form */}
      <form onSubmit={handleSubmit}>
        <ScrollableCartShell
          hasItems={cartItems.length > 0}

          listContent={
            <CartItemList
              items={cartItems.map((item) => ({
                id:          item.id,
                productName: item.productName,
                quantity:    item.quantity,
                unitValue:   item.unitPrice,
                subtotal:    item.subtotal,
                step:        item.step,
                minQty:      item.minQty,
                badge:       item.unitSymbol ?? undefined,
              }))}
              onRemove={handleRemoveItem}
              onUpdateQty={handleUpdateQty}
              onUpdateSubtotal={handleUpdateSubtotal}
              unitLabel="Precio unit."
              currency="ARS"
            />
          }

          footerContent={
            <>
              {cartItems.length > 0 && (
                <div className="rounded-lg border border-border bg-accent/50 p-3">
                  <div className="flex items-center justify-between">
                    <span className="text-sm text-muted-foreground flex items-center gap-2">
                      <ShoppingCart className="h-4 w-4" />
                      Total — {cartItems.length} ítem{cartItems.length !== 1 ? "s" : ""}
                    </span>
                    <span className="text-xl font-bold text-primary tabular-nums">
                      {formatMoney(cartTotal, "ARS")}
                    </span>
                  </div>
                </div>
              )}

              <Button
                type="submit"
                className="w-full"
                size="lg"
                disabled={
                  !isWriter ||
                  submitting ||
                  cartItems.length === 0 ||
                  (paymentMethod === "cash" && !currentSession)
                }
              >
                {submitting
                  ? "Procesando venta…"
                  : cartItems.length > 0
                  ? `Cobrar — ${formatMoney(cartTotal, "ARS")}`
                  : "Cobrar"}
              </Button>
            </>
          }
        >
          {/* ── SECTION: Cliente + Método de pago ─────────────────────────── */}
          <div className="flex flex-col gap-3">

            {/* Cliente (opcional) */}
            <div className="flex flex-col gap-1.5">
              <Label className="text-foreground">
                Cliente
                <span className="ml-1 text-xs text-muted-foreground">(opcional)</span>
              </Label>
              <SearchableSelect
                options={clientOptions}
                value={clientId}
                onValueChange={setClientId}
                placeholder="Consumidor final"
                searchPlaceholder="Buscar cliente…"
                emptyMessage="No se encontraron clientes."
              />
            </div>

            {/* Método de pago */}
            <div className="flex flex-col gap-1.5">
              <Label className="text-foreground">Método de pago</Label>
              <div className="grid grid-cols-2 gap-2">
                <button
                  type="button"
                  onClick={() => setPaymentMethod("cash")}
                  className={[
                    "rounded-lg border py-3 text-sm font-medium transition-colors",
                    paymentMethod === "cash"
                      ? "border-primary bg-primary/10 text-primary"
                      : "border-border bg-background text-muted-foreground hover:text-foreground hover:border-muted-foreground",
                  ].join(" ")}
                >
                  Efectivo
                </button>
                <button
                  type="button"
                  onClick={() => setPaymentMethod("other")}
                  className={[
                    "rounded-lg border py-3 text-sm font-medium transition-colors",
                    paymentMethod === "other"
                      ? "border-primary bg-primary/10 text-primary"
                      : "border-border bg-background text-muted-foreground hover:text-foreground hover:border-muted-foreground",
                  ].join(" ")}
                >
                  Otro / Transferencia
                </button>
              </div>
            </div>

            {/* Cash session status chip */}
            {paymentMethod === "cash" && !sessionLoading && (
              <div
                className={[
                  "flex items-center gap-2 rounded-md px-3 py-2 text-xs",
                  currentSession
                    ? "bg-green-500/10 text-green-700 dark:text-green-400 border border-green-500/20"
                    : "bg-muted text-muted-foreground border border-border",
                ].join(" ")}
              >
                <span
                  className={[
                    "inline-block h-2 w-2 rounded-full",
                    currentSession ? "bg-green-500" : "bg-muted-foreground/40",
                  ].join(" ")}
                />
                {currentSession
                  ? `Caja abierta — sesión ${currentSession.id.slice(0, 8)}…`
                  : "Sin caja abierta"}
              </div>
            )}

            {/* v22: Emission opt-in — deliberate, never automatic */}
            {fiscalProfile && (
              <div className="flex flex-col gap-2 rounded-md border border-border bg-accent/20 p-3">
                <label className="flex items-center gap-2 cursor-pointer select-none">
                  <input
                    type="checkbox"
                    checked={emitirComprobante}
                    onChange={(e) => {
                      setEmitirComprobante(e.target.checked)
                      if (!e.target.checked) setSelectedPvId("")
                    }}
                    className="rounded border-border h-4 w-4 accent-primary"
                  />
                  <span className="text-sm flex items-center gap-1.5">
                    <FileText className="h-3.5 w-3.5 text-muted-foreground" />
                    Emitir comprobante electrónico (ARCA)
                  </span>
                </label>

                {emitirComprobante && (
                  <div className="flex flex-col gap-2 pl-6">
                    {/* Delegation not authorized warning */}
                    {!fiscalProfile.delegacionAutorizada && (
                      <div className="flex items-start gap-2 text-xs text-amber-700 dark:text-amber-400">
                        <AlertCircle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
                        <span>
                          Delegación en ARCA no autorizada.{" "}
                          <Link
                            href="/configuracion/fiscal"
                            className="underline underline-offset-2 hover:opacity-80 inline-flex items-center gap-0.5"
                          >
                            Configurar <ExternalLink className="h-3 w-3" />
                          </Link>
                        </span>
                      </div>
                    )}

                    {/* PV selector — only shown when delegation is ok */}
                    {fiscalProfile.delegacionAutorizada && activePVs.length > 1 && (
                      <div className="flex flex-col gap-1">
                        <Label className="text-[10px] text-muted-foreground">Punto de venta</Label>
                        <Select value={selectedPvId} onValueChange={setSelectedPvId}>
                          <SelectTrigger className="bg-background border-border text-foreground h-9 text-sm">
                            <SelectValue placeholder="Seleccioná un PV" />
                          </SelectTrigger>
                          <SelectContent className="bg-popover border-border">
                            {activePVs.map((pv) => (
                              <SelectItem key={pv.id} value={pv.id}>
                                PV {String(pv.numero).padStart(5, "0")}
                              </SelectItem>
                            ))}
                          </SelectContent>
                        </Select>
                      </div>
                    )}

                    {fiscalProfile.delegacionAutorizada && activePVs.length === 1 && (
                      <span className="text-xs text-muted-foreground">
                        PV {String(activePVs[0]?.numero ?? 1).padStart(5, "0")} — seleccionado automáticamente.
                      </span>
                    )}

                    {fiscalProfile.delegacionAutorizada && activePVs.length === 0 && (
                      <div className="flex items-start gap-2 text-xs text-amber-700 dark:text-amber-400">
                        <AlertCircle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
                        <span>
                          Sin puntos de venta activos.{" "}
                          <Link href="/configuracion/fiscal" className="underline underline-offset-2 hover:opacity-80">
                            Configurar
                          </Link>
                        </span>
                      </div>
                    )}
                  </div>
                )}
              </div>
            )}
          </div>

          <div className="border-t border-border" />

          {/* ── SECTION: Agregar producto ──────────────────────────────────── */}
          <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
            <Label className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
              <PackagePlus className="h-3.5 w-3.5" />
              Agregar producto
            </Label>

            <ProductPicker
              products={products}
              productById={productById}
              unitsById={unitsById}
              value={productId}
              onValueChange={handleProductChange}
              currency="ARS"
            />

            {selectedProduct && (
              <div className="flex flex-col gap-2">
                {/* Precio unitario */}
                <div className="grid grid-cols-2 gap-2">
                  <div className="flex flex-col gap-1">
                    <Label className="text-[10px] text-muted-foreground">Precio unit.</Label>
                    <NumericInput
                      min={0}
                      step={1}
                      value={unitPrice}
                      onValueChange={setUnitPrice}
                      className="bg-background border-border text-foreground"
                    />
                  </div>

                  {/* Cantidad */}
                  <div className="flex flex-col gap-1">
                    <Label className="text-[10px] text-muted-foreground">
                      Cantidad{selectedUnit ? ` (${selectedUnit.symbol})` : ""}
                    </Label>
                    <NumericInput
                      min={stagedMin}
                      step={stagedStep}
                      value={quantity}
                      onValueChange={(val) => setQuantity(Math.max(stagedMin, val))}
                      className="bg-background border-border text-foreground"
                    />
                  </div>
                </div>

                {/* Unidad (si la hay) + Subtotal editable */}
                <div className="grid grid-cols-2 gap-2">
                  <div className="flex flex-col gap-1">
                    <Label className="text-[10px] text-muted-foreground">Unidad</Label>
                    <Select
                      value={unitId || "__none__"}
                      onValueChange={(v) => {
                        const next = v === "__none__" ? "" : v
                        setUnitId(next)
                        const nextUnit = next ? unitsById.get(next) : undefined
                        setQuantity(unitInputMin(nextUnit))
                      }}
                    >
                      <SelectTrigger className="bg-background border-border text-foreground h-10 text-sm">
                        <SelectValue placeholder="Base (×1)" />
                      </SelectTrigger>
                      <SelectContent className="bg-popover border-border">
                        <SelectItem value="__none__">Sin unidad (base)</SelectItem>
                        {units.map((u) => (
                          <SelectItem key={u.id} value={u.id}>
                            {u.symbol} — {u.name}
                          </SelectItem>
                        ))}
                      </SelectContent>
                    </Select>
                  </div>

                  <div className="flex flex-col gap-1">
                    <Label className="text-[10px] text-muted-foreground flex items-center justify-between">
                      Subtotal
                      <span className="text-[9px] text-muted-foreground/70">editable</span>
                    </Label>
                    <NumericInput
                      min={0}
                      value={subtotalFocused ? subtotalDraft : stagedSubtotal}
                      onFocus={(e) => {
                        e.target.select()
                        setSubtotalDraft(stagedSubtotal)
                        setSubtotalFocused(true)
                      }}
                      onBlur={() => setSubtotalFocused(false)}
                      onValueChange={(val) => {
                        setSubtotalDraft(val)
                        setUnitPrice(unitPriceFromSubtotal(val, quantity))
                      }}
                      className="bg-background border-border text-right font-bold text-emerald-400"
                    />
                  </div>
                </div>
              </div>
            )}

            <Button
              type="button"
              variant="secondary"
              onClick={handleAddToCart}
              disabled={!selectedProduct || !isWriter}
              className="w-full gap-2"
            >
              <Plus className="h-4 w-4" />
              Agregar al carrito
            </Button>
          </div>
        </ScrollableCartShell>
      </form>
    </div>
  )
}
