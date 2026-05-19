"use client"

import { useState, useMemo, useCallback } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { CartItemList } from "@/components/shared/cart-item-list"
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { useData } from "@/contexts/data-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { formatMoney, CURRENCIES, type Currency } from "@/lib/format"
import type { SaleOperation } from "@/lib/group-operations"
import { formatPricePerUnit, formatStock } from "@/lib/format-unit"
import {
  unitInputStep,
  unitInputMin,
  toBaseQuantity,
  resolveUnit,
} from "@/lib/unit-utils"
import {
  generateOperationId,
  calcSaleSubtotal,
  calcCartTotal,
  type SaleCartItem,
} from "@/lib/cart-utils"
import { Plus, UserPlus, ShoppingCart, PackagePlus, CalendarIcon, Ruler } from "lucide-react"
import { toast } from "sonner"

interface SaleFormProps {
  onSuccess: () => void
  /** When provided, the form opens in edit mode pre-filled with this operation. */
  editingOperation?: SaleOperation
}

export function SaleForm({ onSuccess, editingOperation }: SaleFormProps) {
  const { products, clients, addSale, addClient, refreshData, updateSaleOperation } = useData()
  const { units, unitsById } = useUnitsOfMeasure()
  const isEdit = !!editingOperation

  // ── Cart state ──────────────────────────────────────────────────────────────
  // In edit mode: pre-populate cart from the existing operation's items.
  // unitPrice = stored amount (already the effective / post-discount price).
  // discount = 0 (not stored separately in DB).
  const [cartItems, setCartItems] = useState<SaleCartItem[]>(() => {
    if (!editingOperation) return []
    return editingOperation.items.map(item => ({
      id:          crypto.randomUUID(),
      productId:   item.productId,
      productName: item.productName,
      unitPrice:   item.unitPrice,
      quantity:    item.quantity,
      discount:    0,
      subtotal:    Math.round(item.unitPrice * item.quantity * 10_000) / 10_000,
    }))
  })

  // ── Current item being staged ───────────────────────────────────────────────
  const [productId, setProductId] = useState("")
  const [quantity, setQuantity] = useState(1)
  const [discount, setDiscount] = useState(0)
  const [unitId, setUnitId] = useState("")

  // ── Header fields (apply to all items) ─────────────────────────────────────
  const [clientId, setClientId] = useState(() => editingOperation?.clientId ?? "")
  const [currency, setCurrency] = useState<Currency>(() => (editingOperation?.currency as Currency) ?? "ARS")
  const [date, setDate] = useState(() => editingOperation?.date ?? new Date().toISOString().split("T")[0])

  // ── Inline new client ───────────────────────────────────────────────────────
  const [showNewClient, setShowNewClient] = useState(false)
  const [newClientName, setNewClientName] = useState("")
  const [newClientEmail, setNewClientEmail] = useState("")
  const [newClientPhone, setNewClientPhone] = useState("")

  // ── Submission state ────────────────────────────────────────────────────────
  const [submitting, setSubmitting] = useState(false)

  // ── Derived ─────────────────────────────────────────────────────────────────
  const selectedProduct = useMemo(
    () => products.find((p) => p.id === productId),
    [products, productId],
  )
  const selectedClient = useMemo(
    () => clients.find((c) => c.id === clientId),
    [clients, clientId],
  )

  // Resolve selected unit from the map (O(1) vs O(n) Array.find)
  const selectedUnit = useMemo(
    () => resolveUnit(unitId, unitsById),
    [unitId, unitsById],
  )

  // Input constraints for the staged quantity — driven by selected unit type
  const stagedStep = useMemo(() => unitInputStep(selectedUnit), [selectedUnit])
  const stagedMin  = useMemo(() => unitInputMin(selectedUnit),  [selectedUnit])

  const cartTotal = useMemo(() => calcCartTotal(cartItems), [cartItems])

  const stagedSubtotal = useMemo(
    () => (selectedProduct ? calcSaleSubtotal(selectedProduct.price, quantity, discount) : 0),
    [selectedProduct, quantity, discount],
  )

  // Quantity converted to base unit — used for local stock validation
  const stagedQuantityNormalized = useMemo(
    () => toBaseQuantity(quantity, selectedUnit),
    [quantity, selectedUnit],
  )

  // ── Option lists ────────────────────────────────────────────────────────────

  // IDs of parent catalogue entries (have at least one variant child).
  // Must NOT appear in the sale dropdown — users must pick a specific variant.
  const parentProductIds = useMemo(() => {
    const ids = new Set<string>()
    for (const p of products) {
      if (p.parentId) ids.add(p.parentId)
    }
    return ids
  }, [products])

  const productById = useMemo(
    () => new Map(products.map((p) => [p.id, p])),
    [products],
  )

  const productOptions = useMemo(
    () =>
      products
        .filter((p) => !parentProductIds.has(p.id))
        .map((p) => {
          const parent = p.parentId ? productById.get(p.parentId) : undefined
          const displayName =
            parent && !p.name.toLowerCase().startsWith(parent.name.toLowerCase())
              ? `${parent.name} › ${p.name}`
              : p.name

          // Resolve base unit for this product to show unit-aware price and stock
          const baseUnit = resolveUnit(p.baseUnitId, unitsById)
          const priceLabel  = formatPricePerUnit(p.price, baseUnit?.symbol, currency)
          const stockLabel  = formatStock(p.stock, baseUnit?.symbol)

          return {
            value: p.id,
            label: `${displayName} — ${priceLabel} (Stock: ${stockLabel})`,
          }
        }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [products, parentProductIds, productById, unitsById, currency],
  )

  const clientOptions = useMemo(
    () => clients.map((c) => ({ value: c.id, label: c.name })),
    [clients],
  )

  // ── Handlers ────────────────────────────────────────────────────────────────

  /**
   * Called by the barcode scanner on each successful scan.
   * Looks up the product by its barcode and directly adds qty 1 to the cart,
   * bypassing the staged-item flow so the user can scan multiple items
   * without clicking "Agregar".
   */
  const handleBarcodeScan = useCallback((barcode: string) => {
    const product = products.find(
      (p) =>
        p.barcode &&
        p.barcode.toUpperCase() === barcode.toUpperCase() &&
        !parentProductIds.has(p.id),
    )

    if (!product) {
      toast.error(`Código "${barcode}" no encontrado`)
      return
    }

    const baseUnit = resolveUnit(product.baseUnitId, unitsById)
    const qty      = unitInputMin(baseUnit)   // honour fractional-unit minimums
    const step     = unitInputStep(baseUnit)

    setCartItems((prev) => {
      const existing = prev.find(
        (item) =>
          item.productId === product.id &&
          (item.unitId ?? "") === (product.baseUnitId ?? ""),
      )

      if (existing) {
        const newQty = existing.quantity + qty
        toast.success(`+${qty} ${product.name}`)
        return prev.map((item) =>
          item.id === existing.id
            ? {
                ...item,
                quantity:     newQty,
                quantityBase: toBaseQuantity(newQty, baseUnit),
                subtotal:     calcSaleSubtotal(product.price, newQty, item.discount),
              }
            : item,
        )
      } else {
        toast.success(`✓ ${product.name}`)
        return [
          ...prev,
          {
            id:           crypto.randomUUID(),
            productId:    product.id,
            productName:  product.name,
            unitPrice:    product.price,
            quantity:     qty,
            discount:     0,
            subtotal:     calcSaleSubtotal(product.price, qty, 0),
            unitId:       product.baseUnitId || undefined,
            unitSymbol:   baseUnit?.symbol,
            unitFactor:   baseUnit?.factor,
            quantityBase: toBaseQuantity(qty, baseUnit),
            step,
            minQty:       qty,
          },
        ]
      }
    })
  }, [products, parentProductIds, unitsById])

  function handleProductChange(id: string) {
    setProductId(id)
    setQuantity(1)
    setDiscount(0)
    // Pre-select the product's base unit so step/min are immediately correct
    const p = products.find((x) => x.id === id)
    setUnitId(p?.baseUnitId ?? "")
  }

  function handleAddToCart() {
    if (!selectedProduct) {
      toast.error("Seleccioná un producto")
      return
    }

    // Existing cart item with same product AND same unit → accumulate quantities
    const existing = cartItems.find(
      (item) => item.productId === productId && (item.unitId ?? "") === unitId,
    )

    if (existing) {
      const newQty           = existing.quantity + quantity
      const newNormalized    = toBaseQuantity(newQty, selectedUnit)
      if (newNormalized > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${formatStock(selectedProduct.stock, selectedUnit?.symbol)})`)
        return
      }
      setCartItems((prev) =>
        prev.map((item) =>
          item.id === existing.id
            ? {
                ...item,
                quantity:      newQty,
                quantityBase:  newNormalized,
                subtotal:      calcSaleSubtotal(selectedProduct.price, newQty, item.discount),
              }
            : item,
        ),
      )
      toast.success(`Cantidad actualizada: ${selectedProduct.name}`)
    } else {
      // New cart entry (different product or different unit)
      if (stagedQuantityNormalized > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${formatStock(selectedProduct.stock, selectedUnit?.symbol)})`)
        return
      }
      setCartItems((prev) => [
        ...prev,
        {
          id:            crypto.randomUUID(),
          productId:     selectedProduct.id,
          productName:   selectedProduct.name,
          unitPrice:     selectedProduct.price,
          quantity,
          discount,
          subtotal:      stagedSubtotal,
          unitId:        unitId || undefined,
          unitSymbol:    selectedUnit?.symbol,
          unitFactor:    selectedUnit?.factor,
          quantityBase:  stagedQuantityNormalized,
          step:          stagedStep,
          minQty:        stagedMin,
        },
      ])
      toast.success(`${selectedProduct.name} agregado`)
    }

    // Reset staged item
    setProductId("")
    setQuantity(1)
    setDiscount(0)
    setUnitId("")
  }

  function handleRemoveItem(id: string) {
    setCartItems((prev) => prev.filter((item) => item.id !== id))
  }

  function handleUpdateQty(id: string, qty: number) {
    setCartItems((prev) =>
      prev.map((item) => {
        if (item.id !== id) return item
        // Use the item's own minQty — not a global 1 — so medibles can go below 1
        const newQty = Math.max(item.minQty ?? 1, qty)
        return {
          ...item,
          quantity:     newQty,
          quantityBase: toBaseQuantity(newQty, resolveUnit(item.unitId, unitsById)),
          subtotal:     calcSaleSubtotal(item.unitPrice, newQty, item.discount),
        }
      }),
    )
  }

  function handleCreateClient() {
    if (!newClientName.trim()) {
      toast.error("El nombre del cliente es obligatorio")
      return
    }
    addClient({
      name:         newClientName,
      email:        newClientEmail,
      phone:        newClientPhone,
      status:       "activo",
      lastPurchase: "-",
      totalSpent:   0,
    })
    toast.success(`Cliente "${newClientName}" creado`)
    setShowNewClient(false)
    setNewClientName("")
    setNewClientEmail("")
    setNewClientPhone("")
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (cartItems.length === 0) {
      toast.error("Agregá al menos un producto al carrito")
      return
    }

    // ── Edit mode ─────────────────────────────────────────────────────────────
    if (isEdit && editingOperation) {
      if (!clientId && !editingOperation.clientId) {
        // Allow null client (Consumidor Final) — do not block edit
      }
      setSubmitting(true)
      try {
        const saleIds = editingOperation.items.map(i => i.id)
        await updateSaleOperation(saleIds, cartItems, {
          clientId: clientId || null,
          date,
          currency,
        })
        toast.success("✅ Venta actualizada correctamente")
        await refreshData()
        onSuccess()
      } catch (err: any) {
        toast.error(`Error al actualizar: ${err.message || "Error desconocido"}`)
      } finally {
        setSubmitting(false)
      }
      return
    }

    // ── Create mode ───────────────────────────────────────────────────────────
    if (!selectedClient) {
      toast.error("Seleccioná un cliente")
      return
    }

    setSubmitting(true)
    const operationId = generateOperationId()

    type Result = { success: boolean; productName: string; error?: string }
    const results: Result[] = []

    for (const item of cartItems) {
      try {
        const effectiveUnitPrice = item.unitPrice * (1 - item.discount / 100)
        await addSale({
          date,
          productId:   item.productId,
          productName: item.productName,
          clientId:    selectedClient.id,
          clientName:  selectedClient.name,
          quantity:    item.quantity,
          unitPrice:   effectiveUnitPrice,
          total:       item.subtotal,
          currency,
          unitId:      item.unitId,
          operationId,
        })
        results.push({ success: true, productName: item.productName })
      } catch (err: any) {
        results.push({
          success:     false,
          productName: item.productName,
          error:       err.message || "Error desconocido",
        })
      }
    }

    const successful = results.filter((r) => r.success)
    const failed     = results.filter((r) => !r.success)

    setSubmitting(false)

    if (failed.length === 0) {
      toast.success(`✅ ${successful.length} producto(s) registrado(s) correctamente`)
      await refreshData()
      onSuccess()
    } else if (successful.length > 0) {
      toast.warning(`⚠️ ${successful.length} registrado(s), ${failed.length} con error`)
      failed.forEach((f) => toast.error(`❌ ${f.productName}: ${f.error}`))
      await refreshData()
      const successNames = new Set(successful.map((s) => s.productName))
      setCartItems((prev) => prev.filter((item) => !successNames.has(item.productName)))
    } else {
      toast.error("No se pudo registrar ningún producto")
      failed.forEach((f) => toast.error(`❌ ${f.productName}: ${f.error}`))
    }
  }

  // ── Dynamic label for the quantity field ─────────────────────────────────────
  const quantityLabel = selectedUnit
    ? `Cantidad (${selectedUnit.symbol})`
    : "Cantidad"

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <form
      onSubmit={handleSubmit}
      className="flex flex-col gap-4 max-h-[80vh] overflow-y-auto pr-1"
    >
      {/* ── Header: Cliente + Moneda + Fecha ────────────────────────────── */}
      <div className="flex flex-col gap-3">
        <div className="flex flex-col gap-2">
          <div className="flex items-center justify-between">
            <Label className="text-foreground">Cliente</Label>
            <Button
              type="button"
              variant="ghost"
              size="sm"
              className="h-6 text-xs text-primary"
              onClick={() => setShowNewClient(!showNewClient)}
            >
              <UserPlus className="h-3 w-3 mr-1" />
              {showNewClient ? "Cancelar" : "Nuevo cliente"}
            </Button>
          </div>

          {showNewClient ? (
            <div className="rounded-lg border border-border bg-accent/30 p-3 flex flex-col gap-2">
              <Input
                selectOnFocus
                value={newClientName}
                onChange={(e) => setNewClientName(e.target.value)}
                placeholder="Nombre del cliente"
                className="bg-background border-border text-foreground text-sm"
              />
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <Input
                  selectOnFocus
                  value={newClientEmail}
                  onChange={(e) => setNewClientEmail(e.target.value)}
                  placeholder="Email (opcional)"
                  className="bg-background border-border text-foreground text-sm"
                />
                <Input
                  selectOnFocus
                  value={newClientPhone}
                  onChange={(e) => setNewClientPhone(e.target.value)}
                  placeholder="Teléfono (opcional)"
                  className="bg-background border-border text-foreground text-sm"
                />
              </div>
              <Button
                type="button"
                size="sm"
                variant="secondary"
                onClick={handleCreateClient}
                className="w-full"
              >
                <Plus className="h-3 w-3 mr-1" />
                Crear y seleccionar
              </Button>
            </div>
          ) : (
            <SearchableSelect
              options={clientOptions}
              value={clientId}
              onValueChange={setClientId}
              placeholder="Seleccionar cliente"
              searchPlaceholder="Buscar cliente..."
              emptyMessage="No se encontraron clientes."
            />
          )}
        </div>

        <div className="grid grid-cols-2 gap-3">
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Moneda</Label>
            <Select value={currency} onValueChange={(v) => setCurrency(v as Currency)}>
              <SelectTrigger className="bg-background border-border text-foreground">
                <SelectValue />
              </SelectTrigger>
              <SelectContent className="bg-popover border-border">
                {CURRENCIES.map((c) => (
                  <SelectItem key={c.value} value={c.value}>
                    {c.symbol} ({c.value})
                  </SelectItem>
                ))}
              </SelectContent>
            </Select>
          </div>

          <div className="flex flex-col gap-2">
            <Label className="text-foreground flex items-center gap-1.5">
              <CalendarIcon className="h-3.5 w-3.5 text-muted-foreground" />
              Fecha
            </Label>
            <input
              type="date"
              value={date}
              max={new Date().toISOString().split("T")[0]}
              onChange={(e) => setDate(e.target.value)}
              className="flex h-10 w-full rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground ring-offset-background focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring focus-visible:ring-offset-2"
            />
          </div>
        </div>
      </div>

      <div className="border-t border-border" />

      {/* ── Product Adder ───────────────────────────────────────────────── */}
      <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
        <div className="flex items-center justify-between">
          <Label className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
            <PackagePlus className="h-3.5 w-3.5" />
            Agregar producto
          </Label>
          <BarcodeScannerInput onScan={handleBarcodeScan} />
        </div>

        <SearchableSelect
          options={productOptions}
          value={productId}
          onValueChange={handleProductChange}
          placeholder="Seleccionar producto"
          searchPlaceholder="Buscar producto..."
          emptyMessage="No se encontraron productos."
        />

        {selectedProduct && (
          <div className="flex flex-col gap-2">
            {/* Row 1: Cantidad + Unidad */}
            <div className="grid grid-cols-2 gap-2">
              <div className="flex flex-col gap-1">
                {/* Dynamic label shows unit symbol when a unit is selected */}
                <Label className="text-[10px] text-muted-foreground">
                  {quantityLabel}
                </Label>
                <NumericInput
                  min={stagedMin}
                  step={stagedStep}
                  value={quantity}
                  onValueChange={(val) => setQuantity(Math.max(stagedMin, val))}
                  className="bg-background border-border text-foreground"
                />
              </div>
              <div className="flex flex-col gap-1">
                <Label className="text-[10px] text-muted-foreground flex items-center gap-1">
                  <Ruler className="h-3 w-3" />
                  Unidad
                </Label>
                <Select
                  value={unitId || "__none__"}
                  onValueChange={(v) => {
                    const next = v === "__none__" ? "" : v
                    setUnitId(next)
                    // Reset quantity to min for new unit type to avoid invalid values
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
            </div>
            {/* Row 2: Descuento + Subtotal */}
            <div className="grid grid-cols-2 gap-2">
              <div className="flex flex-col gap-1">
                <Label className="text-[10px] text-muted-foreground">Descuento (%)</Label>
                <NumericInput
                  min={0}
                  max={100}
                  value={discount}
                  onValueChange={setDiscount}
                  placeholder="0"
                  className="bg-background border-border text-foreground"
                />
              </div>
              <div className="flex flex-col gap-1">
                <Label className="text-[10px] text-muted-foreground">Subtotal</Label>
                <div className="flex h-10 items-center justify-end rounded-md border border-border bg-background px-3 text-sm font-bold text-emerald-400 tabular-nums">
                  {formatMoney(stagedSubtotal, currency)}
                </div>
              </div>
            </div>
          </div>
        )}

        <Button
          type="button"
          variant="secondary"
          onClick={handleAddToCart}
          disabled={!selectedProduct}
          className="w-full gap-2"
        >
          <Plus className="h-4 w-4" />
          Agregar al carrito
        </Button>
      </div>

      {/* ── Cart Items ──────────────────────────────────────────────────── */}
      {cartItems.length > 0 && (
        <CartItemList
          items={cartItems.map((item) => ({
            id:          item.id,
            productName: item.productName,
            quantity:    item.quantity,
            unitValue:   item.unitPrice,
            subtotal:    item.subtotal,
            step:        item.step,
            minQty:      item.minQty,
            badge: [
              item.unitSymbol ?? null,
              item.discount > 0 ? `${item.discount}% desc.` : null,
            ]
              .filter(Boolean)
              .join(" · ") || undefined,
          }))}
          onRemove={handleRemoveItem}
          onUpdateQty={handleUpdateQty}
          unitLabel="Precio unit."
          currency={currency}
        />
      )}

      {/* ── Total ───────────────────────────────────────────────────────── */}
      {cartItems.length > 0 && (
        <div className="rounded-lg border border-border bg-accent/50 p-3">
          <div className="flex items-center justify-between">
            <span className="text-sm text-muted-foreground flex items-center gap-2">
              <ShoppingCart className="h-4 w-4" />
              Total — {cartItems.length} ítem{cartItems.length !== 1 ? "s" : ""}
            </span>
            <span className="text-xl font-bold text-primary tabular-nums">
              {formatMoney(cartTotal, currency)}
            </span>
          </div>
        </div>
      )}

      {/* ── Submit ──────────────────────────────────────────────────────── */}
      <Button
        type="submit"
        className="w-full"
        disabled={submitting || cartItems.length === 0}
      >
        {submitting
          ? isEdit ? "Guardando..." : "Registrando..."
          : isEdit
          ? `Guardar cambios (${cartItems.length} ítem${cartItems.length !== 1 ? "s" : ""})`
          : cartItems.length > 1
          ? `Confirmar venta (${cartItems.length} ítems)`
          : "Confirmar venta"}
      </Button>
    </form>
  )
}
