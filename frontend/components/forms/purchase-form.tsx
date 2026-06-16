"use client"

import { useState, useMemo, useCallback, useRef } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { CartItemList } from "@/components/shared/cart-item-list"
import { BarcodeScannerInput } from "@/components/shared/barcode-scanner-input"
import { useProducts } from "@/hooks/data/use-products"
import { usePurchases } from "@/hooks/data/use-purchases"
import { useQueryClient } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { formatMoney } from "@/lib/format"
import type { PurchaseOperation } from "@/lib/group-operations"
import {
  unitInputStep,
  unitInputMin,
  toBaseQuantity,
  resolveUnit,
} from "@/lib/unit-utils"
import { PRODUCT_CATEGORIES } from "@/lib/constants"
import {
  calcPurchaseSubtotal,
  calcCartTotal,
  unitPriceFromSubtotal,
  type PurchaseCartItem,
} from "@/lib/cart-utils"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { ScrollableCartShell } from "@/components/shared/scrollable-cart-shell"
import { getCanonicalLabel } from "@/lib/product-labels"
import { ProductPicker } from "@/components/shared/product-picker"
import { Plus, PackagePlus, ShoppingCart, CalendarIcon, Ruler } from "lucide-react"
import { toast } from "sonner"
import { BranchSelect } from "@/components/branches/BranchSelect"

interface PurchaseFormProps {
  onSuccess: () => void
  /** When provided, the form opens in edit mode pre-filled with this operation. */
  editingOperation?: PurchaseOperation
}

export function PurchaseForm({ onSuccess, editingOperation }: PurchaseFormProps) {
  const { products, addProduct }                           = useProducts()
  const { addPurchaseOperation, updatePurchaseOperation } = usePurchases()
  const queryClient = useQueryClient()
  const { user }    = useAuth()
  const refreshData = () => queryClient.invalidateQueries()
  const { units, unitsById } = useUnitsOfMeasure()
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey("purchase-create")
  const isEdit = !!editingOperation

  // Synchronous re-entrancy guard: closes the double-click window before the
  // async `submitting` state re-renders the disabled button.
  const submittingRef = useRef(false)

  // ── Cart state ──────────────────────────────────────────────────────────────
  // In edit mode: pre-populate from the existing operation's items.
  const [cartItems, setCartItems] = useState<PurchaseCartItem[]>(() => {
    if (!editingOperation) return []
    return editingOperation.items.map(item => ({
      id:          crypto.randomUUID(),
      productId:   item.productId,
      productName: item.productName,
      unitCost:    item.unitCost,
      quantity:    item.quantity,
      subtotal:    Math.round(item.unitCost * item.quantity * 10_000) / 10_000,
    }))
  })

  // ── Current item being staged ───────────────────────────────────────────────
  const [productId, setProductId] = useState("")
  const [unitCost, setUnitCost] = useState(0)
  const [quantity, setQuantity] = useState(1)
  const [unitId, setUnitId] = useState("")

  // Subtotal editable: the user can type the line total and we back-compute the
  // effective unit cost. Focused-draft avoids rounding flicker when qty > 1.
  const [subtotalFocused, setSubtotalFocused] = useState(false)
  const [subtotalDraft, setSubtotalDraft] = useState(0)

  // ── Global description (one note per operation) ─────────────────────────────
  const [description, setDescription] = useState(() => editingOperation?.description ?? "")

  // ── Inline new product ──────────────────────────────────────────────────────
  const [showNewProduct, setShowNewProduct] = useState(false)
  const [newProductName, setNewProductName] = useState("")
  const [newProductCategory, setNewProductCategory] = useState("")
  const [newProductCost, setNewProductCost] = useState(0)
  const [newProductPrice, setNewProductPrice] = useState(0)
  const [newProductMinStock, setNewProductMinStock] = useState(10)

  // ── Operation date ──────────────────────────────────────────────────────────
  const [date, setDate] = useState(() => editingOperation?.date ?? new Date().toISOString().split("T")[0])
  const [branchId, setBranchId] = useState<string | null>(null)

  // ── Submission state ────────────────────────────────────────────────────────
  const [submitting, setSubmitting] = useState(false)

  // ── Derived ─────────────────────────────────────────────────────────────────
  const selectedProduct = useMemo(
    () => products.find((p) => p.id === productId),
    [products, productId],
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
    () => calcPurchaseSubtotal(unitCost, quantity),
    [unitCost, quantity],
  )

  // ── Option list ─────────────────────────────────────────────────────────────

  // IDs of parent catalogue entries (have at least one variant child).
  // Must NOT appear in the purchase dropdown — users must pick a specific variant.
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
    const qty      = unitInputMin(baseUnit)
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
                unitCost:     item.unitCost,
                subtotal:     calcPurchaseSubtotal(item.unitCost, newQty),
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
            productName:  getCanonicalLabel(product, product.parentId ? productById.get(product.parentId) : undefined),
            unitCost:     product.cost,
            quantity:     qty,
            subtotal:     calcPurchaseSubtotal(product.cost, qty),
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
  }, [products, parentProductIds, unitsById, productById])

  function handleProductChange(id: string) {
    setProductId(id)
    const p = products.find((x) => x.id === id)
    if (p) setUnitCost(p.cost)
    // Pre-select the product's base unit so step/min are immediately correct
    const nextUnitId = p?.baseUnitId ?? ""
    setUnitId(nextUnitId)
    const nextUnit = resolveUnit(nextUnitId, unitsById)
    setQuantity(unitInputMin(nextUnit))
  }

  function handleAddToCart() {
    if (!selectedProduct) {
      toast.error("Seleccioná un producto")
      return
    }
    if (unitCost <= 0) {
      toast.error("El costo unitario debe ser mayor a 0")
      return
    }

    // Existing cart item with same product AND same unit → accumulate quantities
    const existing = cartItems.find(
      (item) => item.productId === productId && (item.unitId ?? "") === unitId,
    )
    if (existing) {
      const newQty = existing.quantity + quantity
      setCartItems((prev) =>
        prev.map((item) =>
          item.id === existing.id
            ? {
                ...item,
                quantity:     newQty,
                quantityBase: toBaseQuantity(newQty, selectedUnit),
                unitCost,
                subtotal:     calcPurchaseSubtotal(unitCost, newQty),
              }
            : item,
        ),
      )
      toast.success(`Cantidad actualizada: ${selectedProduct.name}`)
    } else {
      setCartItems((prev) => [
        ...prev,
        {
          id:           crypto.randomUUID(),
          productId:    selectedProduct.id,
          productName:  getCanonicalLabel(selectedProduct, selectedProduct.parentId ? productById.get(selectedProduct.parentId) : undefined),
          unitCost,
          quantity,
          subtotal:     stagedSubtotal,
          unitId:       unitId || undefined,
          unitSymbol:   selectedUnit?.symbol,
          unitFactor:   selectedUnit?.factor,
          quantityBase: toBaseQuantity(quantity, selectedUnit),
          step:         stagedStep,
          minQty:       stagedMin,
        },
      ])
      toast.success(`${selectedProduct.name} agregado`)
    }
    // Reset staged item
    setProductId("")
    setUnitCost(0)
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
        // Use the item's own minQty — not a global 1 — so medibles can go below 1
        const newQty = Math.max(item.minQty ?? 1, qty)
        return {
          ...item,
          quantity:     newQty,
          quantityBase: toBaseQuantity(newQty, resolveUnit(item.unitId, unitsById)),
          subtotal:     calcPurchaseSubtotal(item.unitCost, newQty),
        }
      }),
    )
  }

  // Edit the subtotal of an item already in the cart: back-compute unit cost.
  function handleUpdateSubtotal(id: string, newSubtotal: number) {
    setCartItems((prev) =>
      prev.map((item) =>
        item.id === id
          ? {
              ...item,
              unitCost: unitPriceFromSubtotal(newSubtotal, item.quantity),
              subtotal: newSubtotal,
            }
          : item,
      ),
    )
  }

  function handleCreateProduct() {
    if (!newProductName.trim() || !newProductCategory) {
      toast.error("Nombre y categoría son obligatorios")
      return
    }
    const margin =
      newProductPrice > 0
        ? Math.round(((newProductPrice - newProductCost) / newProductPrice) * 100)
        : 0
    addProduct({
      name:             newProductName,
      category:         newProductCategory,
      cost:             newProductCost,
      price:            newProductPrice,
      margin,
      stock:            0,
      minStock:         newProductMinStock,
      isVariant:        false,
      stockControlType: "tracked",  // explicit default — never undefined
    })
    toast.success(`Producto "${newProductName}" creado`)
    setUnitCost(newProductCost)
    setShowNewProduct(false)
    setNewProductName("")
    setNewProductCategory("")
    setNewProductCost(0)
    setNewProductPrice(0)
    setNewProductMinStock(10)
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (cartItems.length === 0) {
      toast.error("Agregá al menos un producto al carrito")
      return
    }
    if (submittingRef.current) return
    submittingRef.current = true

    // ── Edit mode ─────────────────────────────────────────────────────────────
    if (isEdit && editingOperation) {
      setSubmitting(true)
      try {
        const purchaseIds = editingOperation.items.map(i => i.id)
        await updatePurchaseOperation({
          purchaseIds,
          newItems: cartItems,
          meta: { date, description, orgId: user?.accountId ?? "" },
        })
        toast.success("✅ Compra actualizada correctamente")
        await refreshData()
        onSuccess()
      } catch (err: any) {
        toast.error(`Error al actualizar: ${err.message || "Error desconocido"}`)
      } finally {
        setSubmitting(false)
        submittingRef.current = false
      }
      return
    }

    // ── Create mode ───────────────────────────────────────────────────────────
    setSubmitting(true)
    try {
      // One atomic, idempotent call for the whole cart (see SaleForm rationale).
      await addPurchaseOperation({
        items: cartItems,
        meta: {
          idempotencyKey: idempotencyKey,
          date,
          description,
          branchId,
          orgId: user?.accountId ?? "",
        },
      })
      resetIdempotencyKey()
      toast.success(
        cartItems.length > 1
          ? `✅ Compra registrada (${cartItems.length} ítems)`
          : "✅ Compra registrada correctamente",
      )
      await refreshData()
      onSuccess()
    } catch (err: any) {
      toast.error(`Error al registrar la compra: ${err.message || "Error desconocido"}`)
    } finally {
      setSubmitting(false)
      submittingRef.current = false
    }
  }

  // ── Dynamic label for the quantity field ─────────────────────────────────────
  const quantityLabel = selectedUnit
    ? `Cantidad (${selectedUnit.symbol})`
    : "Cantidad"

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <form onSubmit={handleSubmit}>
      <ScrollableCartShell
        hasItems={cartItems.length > 0}

        // ── Scrollable cart list ─────────────────────────────────────────
        listContent={
          <CartItemList
            items={cartItems.map((item) => ({
              id:          item.id,
              productName: item.productName,
              quantity:    item.quantity,
              unitValue:   item.unitCost,
              subtotal:    item.subtotal,
              step:        item.step,
              minQty:      item.minQty,
              badge:       item.unitSymbol ?? undefined,
            }))}
            onRemove={handleRemoveItem}
            onUpdateQty={handleUpdateQty}
            onUpdateSubtotal={handleUpdateSubtotal}
            unitLabel="Costo unit."
          />
        }

        // ── Sticky footer: total + submit ────────────────────────────────
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
                    {formatMoney(cartTotal)}
                  </span>
                </div>
              </div>
            )}

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
                ? `Confirmar compra (${cartItems.length} ítems)`
                : "Confirmar compra"}
            </Button>
          </>
        }
      >
        {/* ── HEADER: Fecha + Notas ────────────────────────────────────── */}
        {/* Moved to top so meta-info is set before adding items (UX parity with SaleForm) */}
        <div className="grid grid-cols-2 gap-3">
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

          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Notas (opcional)</Label>
            <Input
              selectOnFocus
              value={description}
              onChange={(e) => setDescription(e.target.value)}
              placeholder="Ej: Lote Dic 2026"
              className="bg-background border-border text-foreground"
            />
          </div>

          {/* ── Sucursal (solo plan PRO) ───────────────────────────────── */}
          <BranchSelect
            value={branchId}
            onChange={setBranchId}
            placeholder="Sin sucursal (general)"
            className="bg-background border-border text-foreground text-sm"
          />
        </div>

        <div className="border-t border-border" />

        {/* ── HEADER: Product Adder ────────────────────────────────────── */}
        <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
          <div className="flex items-center justify-between">
            <Label className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
              <PackagePlus className="h-3.5 w-3.5" />
              Agregar producto
            </Label>
            <div className="flex items-center gap-2">
              <BarcodeScannerInput onScan={handleBarcodeScan} />
              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="h-6 text-xs text-primary"
                onClick={() => setShowNewProduct(!showNewProduct)}
              >
                <Plus className="h-3 w-3 mr-1" />
                {showNewProduct ? "Cancelar" : "Nuevo producto"}
              </Button>
            </div>
          </div>

          {showNewProduct ? (
            <div className="rounded-lg border border-border bg-accent/30 p-3 flex flex-col gap-2">
              <Input
                selectOnFocus
                value={newProductName}
                onChange={(e) => setNewProductName(e.target.value)}
                placeholder="Nombre del producto"
                className="bg-background border-border text-foreground text-sm"
              />
              <Select value={newProductCategory} onValueChange={setNewProductCategory}>
                <SelectTrigger className="bg-background border-border text-foreground text-sm">
                  <SelectValue placeholder="Categoría" />
                </SelectTrigger>
                <SelectContent className="bg-popover border-border">
                  {PRODUCT_CATEGORIES.map((c) => (
                    <SelectItem key={c} value={c}>
                      {c}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <div className="grid grid-cols-1 sm:grid-cols-3 gap-2">
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Costo</Label>
                  <NumericInput
                    min={0}
                    value={newProductCost}
                    onValueChange={setNewProductCost}
                    className="bg-background border-border text-foreground text-sm"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Precio venta</Label>
                  <NumericInput
                    min={0}
                    value={newProductPrice}
                    onValueChange={setNewProductPrice}
                    className="bg-background border-border text-foreground text-sm"
                  />
                </div>
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Stock mín.</Label>
                  <NumericInput
                    min={0}
                    value={newProductMinStock}
                    onValueChange={setNewProductMinStock}
                    className="bg-background border-border text-foreground text-sm"
                  />
                </div>
              </div>
              <Button
                type="button"
                size="sm"
                variant="secondary"
                onClick={handleCreateProduct}
                className="w-full"
              >
                <Plus className="h-3 w-3 mr-1" />
                Crear y seleccionar
              </Button>
            </div>
          ) : (
            <ProductPicker
              products={products}
              productById={productById}
              unitsById={unitsById}
              value={productId}
              onValueChange={handleProductChange}
            />
          )}

          {selectedProduct && !showNewProduct && (
            <div className="flex flex-col gap-2">
              {/* Row 1: Cantidad + Unidad */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <div className="flex flex-col gap-1">
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
              {/* Row 2: Costo unitario + Subtotal */}
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <div className="flex flex-col gap-1">
                  <Label className="text-[10px] text-muted-foreground">Costo unitario</Label>
                  <NumericInput
                    min={0}
                    step={0.01}
                    value={unitCost}
                    onValueChange={setUnitCost}
                    className="bg-background border-border text-foreground"
                  />
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
                      // Fijar el costo efectivo a partir del subtotal tipeado.
                      setUnitCost(unitPriceFromSubtotal(val, quantity))
                    }}
                    className="bg-background border-border text-right font-bold text-cyan-400"
                  />
                </div>
              </div>
            </div>
          )}

          <Button
            type="button"
            variant="secondary"
            onClick={handleAddToCart}
            disabled={!selectedProduct || showNewProduct}
            className="w-full gap-2"
          >
            <Plus className="h-4 w-4" />
            Agregar al carrito
          </Button>
        </div>
      </ScrollableCartShell>
    </form>
  )
}
