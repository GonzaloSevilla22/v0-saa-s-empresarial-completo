"use client"

/**
 * C-29 v21-quote-salesorder — POS quickSale screen.
 * pos-catalogo-pagos — la grilla del catálogo reemplaza el par hardcodeado
 * cash/other (D7); credit exige cliente y muestra saldo (D8); la caja se
 * condiciona al kind RESUELTO, no al texto (D5).
 *
 * Fast mostrador flow: pick products → build cart → choose payment
 * method (catálogo de la cuenta) → resolve cash session (if cash) →
 * submit via useQuickSale.
 *
 * Mirrors the Ventas page for auth guard + NoWriteAccessBanner.
 * Reuses: ProductPicker, CartItemList, ScrollableCartShell, SearchableSelect,
 * usePaymentMethods (metodos-pago-operaciones), useCustomerAccount (C-30) —
 * regla "reutilización antes que repetición".
 *
 * Cash session integration:
 *   - Fetches branches → first branch → cashboxes → first cashbox → currentSession.
 *   - Blocks submit if kind resuelto = 'cash' y no hay sesión abierta.
 *   - Para cualquier otro kind, no se exige sesión (cash_session_id omitido).
 */

import { useState, useMemo, useRef, useCallback } from "react"
import Link from "next/link"
import { ShoppingCart, PackagePlus, Plus, AlertCircle, CheckCircle2 } from "lucide-react"
import { toast } from "sonner"

import { Celebration3D } from "@/components/three/Celebration3D"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { NumericInput } from "@/components/ui/numeric-input"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { CartItemList } from "@/components/shared/cart-item-list"
import { ScrollableCartShell } from "@/components/shared/scrollable-cart-shell"
import { ProductPicker } from "@/components/shared/product-picker"
import { NoWriteAccessBanner } from "@/components/shared/NoWriteAccessBanner"

import { useOrgRole } from "@/hooks/useOrgRole"
import { useProducts } from "@/hooks/data/use-products"
import { useClients } from "@/hooks/data/use-clients"
import { useBranches } from "@/hooks/data/use-branches"
import { useCashboxes } from "@/hooks/data/use-cashboxes"
import { useCurrentSession } from "@/hooks/data/use-cash-session"
import { useQuickSale, type QuickSaleInput } from "@/hooks/data/use-sales-orders"
import { usePaymentMethods } from "@/hooks/data/use-payment-methods"
import { useCustomerAccount } from "@/hooks/data/use-customer-account"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"

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
  // pos-catalogo-pagos (D2, task 6.6): errores nuevos de resolución de forma de pago.
  if (message.includes("credit_requires_client"))
    return "Elegí un cliente: una venta a cuenta corriente se le carga a alguien."
  if (message.includes("payment_method_not_found"))
    return "Esa forma de pago no existe en tu cuenta. Elegí otra."
  if (message.includes("payment_method_inactive"))
    return "Esa forma de pago está desactivada. Elegí otra o reactivala en Configuración."
  if (message.includes("payment_method_mismatch"))
    return "La forma de pago no coincide con lo esperado. Volvé a elegirla e intentá de nuevo."
  return message || "Ocurrió un error inesperado."
}

// ── Last-sale summary state ───────────────────────────────────────────────────

interface LastSaleResult {
  salesOrderId: string
  total: number
  /** pos-catalogo-pagos D8: si la venta fue a cuenta corriente, el card de
   *  éxito enlaza a la cuenta del cliente en vez de solo a /ventas/ordenes. */
  wasCredit: boolean
  clientId: string | null
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

  // ── Catálogo de formas de pago (pos-catalogo-pagos D7) ────────────────────────
  // Reutiliza usePaymentMethods (metodos-pago-operaciones) — el backend ya
  // ordena por sort_order. Solo activas (default de la firma).
  const { paymentMethods, isLoading: methodsLoading } = usePaymentMethods()

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
  const [clientId, setClientId] = useState("")

  // pos-catalogo-pagos (D7): el método elegido es un id del catálogo. Sin
  // selección explícita del usuario, el default es 'cash' de menor
  // sort_order (o el primero activo si no hay cash). Derivado, no efecto.
  const [userSelectedMethodId, setUserSelectedMethodId] = useState<string | null>(null)

  const defaultPaymentMethod = useMemo(() => {
    if (paymentMethods.length === 0) return null
    return paymentMethods.find((pm) => pm.kind === "cash") ?? paymentMethods[0]
  }, [paymentMethods])

  const selectedPaymentMethod = useMemo(() => {
    if (userSelectedMethodId) {
      return paymentMethods.find((pm) => pm.id === userSelectedMethodId) ?? defaultPaymentMethod
    }
    return defaultPaymentMethod
  }, [userSelectedMethodId, paymentMethods, defaultPaymentMethod])

  // D2: el "kind resuelto" — null cuando la cuenta no tiene ningún método
  // activo (D7: degradar al camino legacy 'other', nunca impedir el cobro).
  const resolvedKind = selectedPaymentMethod?.kind ?? null
  const noActiveMethods = !methodsLoading && paymentMethods.length === 0

  // ── Cuenta corriente (D8, resuelve OQ-2) ──────────────────────────────────────
  const isCreditSelected = resolvedKind === "credit"
  const { data: customerAccount } = useCustomerAccount(isCreditSelected ? (clientId || null) : null)
  const creditBlockedNoClient = isCreditSelected && !clientId

  // ── Submission state ──────────────────────────────────────────────────────────
  const [submitting,  setSubmitting]  = useState(false)
  const submittingRef                  = useRef(false)
  const [lastSale,    setLastSale]    = useState<LastSaleResult | null>(null)

  // ── Idempotency key (per-tab, stable across F5) ───────────────────────────────
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey("pos-quick-sale")

  // ── Mutation ──────────────────────────────────────────────────────────────────
  const quickSale = useQuickSale()

  // facturar-venta-afip: el opt-in de emisión del POS fue eliminado.
  // La emisión ocurre DESPUÉS de confirmar, vía el botón "Facturar" en la lista
  // de órdenes (/ventas/ordenes). El payload ya no incluye comprobante_type.

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

  // pos-catalogo-pagos D8: saldo proyectado tras esta venta (0 si aún no
  // resolvió la CustomerAccount — degrada a mostrar solo el total del carrito).
  const projectedBalance = (customerAccount?.balance ?? 0) + cartTotal

  const clientOptions = useMemo(
    () => clients.map((c) => ({ value: c.id, label: c.name })),
    [clients],
  )

  // ── Cash session validation (pos-catalogo-pagos D5: sobre el kind RESUELTO,
  // no sobre el texto elegido — un id de kind='cash' se comporta igual que
  // el legacy 'cash') ───────────────────────────────────────────────────────
  const cashSessionMissing =
    resolvedKind === "cash" &&
    !sessionLoading &&
    firstCashbox !== null &&
    !currentSession

  const noCashboxForBranch =
    resolvedKind === "cash" &&
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
    setUserSelectedMethodId(null)
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

    // Cash (kind resuelto) sin sesión abierta → block
    if (resolvedKind === "cash" && !currentSession) {
      toast.error("No hay caja abierta. Abrí una sesión de caja antes de cobrar en efectivo.")
      submittingRef.current = false
      return
    }

    // pos-catalogo-pagos D8: crédito exige cliente — el backend es la
    // verdad (credit_requires_client), esto solo evita el viaje.
    if (creditBlockedNoClient) {
      toast.error("Elegí un cliente: una venta a cuenta corriente se le carga a alguien.")
      submittingRef.current = false
      return
    }

    setSubmitting(true)
    setLastSale(null)

    // facturar-venta-afip: el POS ya NO emite comprobantes inline.
    // La venta nace sin comprobante; el botón "Facturar" en el detalle
    // de la venta emite para cualquier SalesOrder confirmada.
    // Se elimina el hardcode `comprobante_type: "factura_c"` (causa raíz del bug fiscal).
    //
    // pos-catalogo-pagos (D2/D6): se manda payment_method_id (el id elegido
    // del catálogo, o null en el camino legacy) Y payment_method (el kind
    // resuelto en memoria — usePaymentMethods ya lo trae, sin fetch extra).
    // La RPC re-deriva y compara; el cliente no elige la taxonomía.
    const payload: QuickSaleInput = {
      idempotency_key:    idempotencyKey,
      client_id:          clientId || null,
      payment_method:     resolvedKind ?? "other",
      payment_method_id:  selectedPaymentMethod?.id ?? null,
      cash_session_id:    resolvedKind === "cash" ? (currentSession?.id ?? null) : null,
      branch_id:          activeBranch?.id ?? null,
      // comprobante_type y point_of_sale_id se omiten intencionalmente:
      // la emisión ocurre DESPUÉS de confirmar, vía el endpoint /emit-invoice.
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
        salesOrderId: result.sales_order_id,
        total:        Number(result.total),
        wasCredit:    isCreditSelected,
        clientId:     clientId || null,
      })
      setCartItems([])
      setClientId("")
      toast.success(
        cartItems.length > 1
          ? `Venta registrada (${cartItems.length} ítems) — $${Number(result.total).toLocaleString("es-AR")}`
          : "Venta registrada correctamente",
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

      {/* Celebración "venta cerrada" (v4-visual-3d-refresh 3.5) — puramente
          presentacional, efímera, `key` por venta re-dispara el burst en cada
          venta nueva; JAMÁS bloquea el flujo de cobro (overlay pointer-events-none). */}
      <Celebration3D key={lastSale?.salesOrderId ?? "none"} show={!!lastSale} variant="sale" />

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
            {/* facturar-venta-afip: la emisión ocurre en /ventas/ordenes */}
            <Link
              href="/ventas/ordenes"
              className="text-xs underline underline-offset-2 text-green-600/80 dark:text-green-400/80 hover:opacity-80 mt-0.5"
            >
              Facturar esta venta →
            </Link>
            {/* pos-catalogo-pagos D8: venta a cuenta corriente enlaza a la cuenta del cliente */}
            {lastSale.wasCredit && lastSale.clientId && (
              <Link
                href={`/clientes/${lastSale.clientId}/cuenta`}
                className="text-xs underline underline-offset-2 text-green-600/80 dark:text-green-400/80 hover:opacity-80 mt-0.5"
              >
                Ver cuenta corriente del cliente →
              </Link>
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

      {/* Cash session warning — solo cuando el kind resuelto es 'cash' (D5) */}
      {(cashSessionMissing || noCashboxForBranch) && resolvedKind === "cash" && (
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
                : "Abrí una sesión de caja antes de cobrar en efectivo, o elegí otra forma de pago."}
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
                  (resolvedKind === "cash" && !currentSession) ||
                  creditBlockedNoClient
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

            {/* Método de pago — pos-catalogo-pagos D7: grilla del catálogo de
                la cuenta, no un vocabulario fijo. grid-cols-2 en mobile,
                grid-cols-3 en desktop; targets ≥44px (h-11). */}
            <div className="flex flex-col gap-1.5">
              <Label className="text-foreground">Método de pago</Label>

              {noActiveMethods ? (
                <div className="flex items-start gap-2 rounded-md border border-border bg-muted/40 px-3 py-2 text-xs text-muted-foreground">
                  <AlertCircle className="h-3.5 w-3.5 mt-0.5 shrink-0" />
                  <span>
                    No hay formas de pago activas en tu cuenta. La venta se cobra igual, sin
                    imputar.{" "}
                    <Link href="/configuracion" className="underline underline-offset-2 hover:opacity-80">
                      Configurar catálogo →
                    </Link>
                  </span>
                </div>
              ) : (
                <div className="grid grid-cols-2 sm:grid-cols-3 gap-2">
                  {paymentMethods.map((pm) => {
                    const isSelected = selectedPaymentMethod?.id === pm.id
                    return (
                      <button
                        key={pm.id}
                        type="button"
                        aria-pressed={isSelected}
                        onClick={() => setUserSelectedMethodId(pm.id)}
                        className={[
                          "min-h-[44px] rounded-lg border px-3 py-3 text-sm font-medium transition-colors",
                          isSelected
                            ? "border-primary bg-primary/10 text-primary"
                            : "border-border bg-background text-muted-foreground hover:text-foreground hover:border-muted-foreground",
                        ].join(" ")}
                      >
                        {pm.name}
                      </button>
                    )
                  })}
                </div>
              )}
            </div>

            {/* Cash session status chip — solo cuando el kind resuelto es 'cash' (D5) */}
            {resolvedKind === "cash" && !sessionLoading && (
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

            {/* Bloque de cuenta corriente — pos-catalogo-pagos D8 (resuelve OQ-2):
                cliente obligatorio + saldo actual/proyectado, solo con 'credit'. */}
            {isCreditSelected && (
              <div className="flex flex-col gap-1.5 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs">
                {creditBlockedNoClient ? (
                  <div className="flex items-center gap-2 text-amber-700 dark:text-amber-400">
                    <AlertCircle className="h-3.5 w-3.5 shrink-0" />
                    <span>
                      Elegí un cliente: una venta a cuenta corriente se le carga a alguien.
                    </span>
                  </div>
                ) : (
                  <div className="flex items-center justify-between gap-2 text-muted-foreground">
                    <span>Saldo actual: {formatMoney(customerAccount?.balance ?? 0, "ARS")}</span>
                    <span className="font-medium text-foreground">
                      Después de esta venta: {formatMoney(projectedBalance, "ARS")}
                    </span>
                  </div>
                )}
              </div>
            )}

            {/* facturar-venta-afip: emisión disponible en /ventas/ordenes tras confirmar */}
            <div className="flex items-center gap-2 rounded-md border border-border bg-accent/20 px-3 py-2 text-xs text-muted-foreground">
              <AlertCircle className="h-3.5 w-3.5 shrink-0" />
              <span>
                La facturación electrónica se realiza{" "}
                <Link href="/ventas/ordenes" className="underline underline-offset-2 hover:opacity-80">
                  después de confirmar la venta
                </Link>
                .
              </span>
            </div>
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
