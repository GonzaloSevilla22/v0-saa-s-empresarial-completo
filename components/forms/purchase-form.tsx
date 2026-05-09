"use client"

import { useState, useMemo } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { SearchableSelect } from "@/components/ui/searchable-select"
import { CartItemList } from "@/components/shared/cart-item-list"
import { useData } from "@/contexts/data-context"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { formatMoney } from "@/lib/format"
import { PRODUCT_CATEGORIES } from "@/lib/constants"
import {
  generateOperationId,
  calcPurchaseSubtotal,
  calcCartTotal,
  type PurchaseCartItem,
} from "@/lib/cart-utils"
import { Plus, PackagePlus, ShoppingCart, CalendarIcon, Ruler } from "lucide-react"
import { toast } from "sonner"

interface PurchaseFormProps {
  onSuccess: () => void
}

export function PurchaseForm({ onSuccess }: PurchaseFormProps) {
  const { products, addPurchase, addProduct, refreshData } = useData()
  const { units } = useUnitsOfMeasure()

  // ── Cart state ──────────────────────────────────────────────────────────────
  const [cartItems, setCartItems] = useState<PurchaseCartItem[]>([])

  // ── Current item being staged ───────────────────────────────────────────────
  const [productId, setProductId] = useState("")
  const [unitCost, setUnitCost] = useState(0)
  const [quantity, setQuantity] = useState(1)
  const [unitId, setUnitId] = useState("")

  // ── Global description (one note per operation) ─────────────────────────────
  const [description, setDescription] = useState("")

  // ── Inline new product ──────────────────────────────────────────────────────
  const [showNewProduct, setShowNewProduct] = useState(false)
  const [newProductName, setNewProductName] = useState("")
  const [newProductCategory, setNewProductCategory] = useState("")
  const [newProductCost, setNewProductCost] = useState(0)
  const [newProductPrice, setNewProductPrice] = useState(0)
  const [newProductMinStock, setNewProductMinStock] = useState(10)

  // ── Operation date ──────────────────────────────────────────────────────────
  const [date, setDate] = useState(() => new Date().toISOString().split("T")[0])

  // ── Submission state ────────────────────────────────────────────────────────
  const [submitting, setSubmitting] = useState(false)

  // ── Derived ─────────────────────────────────────────────────────────────────
  const selectedProduct = useMemo(
    () => products.find((p) => p.id === productId),
    [products, productId],
  )
  const selectedUnit = useMemo(
    () => units.find((u) => u.id === unitId),
    [units, unitId],
  )
  const cartTotal = useMemo(() => calcCartTotal(cartItems), [cartItems])
  const stagedSubtotal = useMemo(
    () => calcPurchaseSubtotal(unitCost, quantity),
    [unitCost, quantity],
  )

  // ── Option list ─────────────────────────────────────────────────────────────

  // IDs of products that are "parent catalogue entries" (have at least one variant child).
  // These must NOT appear in the purchase dropdown — users must pick a specific variant.
  const parentProductIds = useMemo(() => {
    const ids = new Set<string>()
    for (const p of products) {
      if (p.parentId) ids.add(p.parentId)
    }
    return ids
  }, [products])

  // Quick lookup by id for parent-name prefix in variant labels
  const productById = useMemo(
    () => new Map(products.map((p) => [p.id, p])),
    [products],
  )

  const productOptions = useMemo(
    () =>
      products
        .filter((p) => !parentProductIds.has(p.id)) // exclude parent catalogue entries
        .map((p) => {
          const parent = p.parentId ? productById.get(p.parentId) : undefined
          const displayName =
            parent && !p.name.toLowerCase().startsWith(parent.name.toLowerCase())
              ? `${parent.name} › ${p.name}`
              : p.name
          return {
            value: p.id,
            label: `${displayName} (Costo: ${formatMoney(p.cost)})`,
          }
        }),
    [products, parentProductIds, productById],
  )

  // ── Handlers ────────────────────────────────────────────────────────────────

  function handleProductChange(id: string) {
    setProductId(id)
    const p = products.find((x) => x.id === id)
    if (p) setUnitCost(p.cost)
    setQuantity(1)
    // Pre-select the product's default unit (set in Etapa 5 backfill)
    setUnitId(p?.baseUnitId ?? "")
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

    // Existing cart item with the SAME product AND same unit → accumulate quantities
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
                quantity: newQty,
                unitCost,
                subtotal: calcPurchaseSubtotal(unitCost, newQty),
              }
            : item,
        ),
      )
      toast.success(`Cantidad actualizada: ${selectedProduct.name}`)
    } else {
      setCartItems((prev) => [
        ...prev,
        {
          id: crypto.randomUUID(),
          productId: selectedProduct.id,
          productName: selectedProduct.name,
          unitCost,
          quantity,
          subtotal: stagedSubtotal,
          unitId: unitId || undefined,
          unitSymbol: selectedUnit?.symbol,
          unitFactor: selectedUnit?.factor,
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
        const newQty = Math.max(1, qty)
        return { ...item, quantity: newQty, subtotal: calcPurchaseSubtotal(item.unitCost, newQty) }
      }),
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
      name: newProductName,
      category: newProductCategory,
      cost: newProductCost,
      price: newProductPrice,
      margin,
      stock: 0,
      minStock: newProductMinStock,
      isVariant: false, // quick-created products are always standalone
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

    setSubmitting(true)
    const operationId = generateOperationId()

    type Result = { success: boolean; productName: string; error?: string }
    const results: Result[] = []

    for (const item of cartItems) {
      try {
        await addPurchase({
          date,
          productId: item.productId,
          productName: item.productName,
          quantity: item.quantity,
          unitCost: item.unitCost,
          total: item.subtotal,
          description: description || `Compra de ${item.productName}`,
          unitId: item.unitId,
          operationId,
        })
        results.push({ success: true, productName: item.productName })
      } catch (err: any) {
        results.push({
          success: false,
          productName: item.productName,
          error: err.message || "Error desconocido",
        })
      }
    }

    const successful = results.filter((r) => r.success)
    const failed = results.filter((r) => !r.success)

    setSubmitting(false)

    if (failed.length === 0) {
      toast.success(`✅ ${successful.length} producto(s) registrado(s) correctamente`)
      await refreshData()
      onSuccess()
    } else if (successful.length > 0) {
      // Partial success — keep dialog open, remove done items from cart
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

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <form
      onSubmit={handleSubmit}
      className="flex flex-col gap-4 max-h-[80vh] overflow-y-auto pr-1"
    >
      {/* ── Product Adder ───────────────────────────────────────────────── */}
      <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
        <div className="flex items-center justify-between">
          <Label className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
            <PackagePlus className="h-3.5 w-3.5" />
            Agregar producto
          </Label>
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
            <div className="grid grid-cols-3 gap-2">
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
          <SearchableSelect
            options={productOptions}
            value={productId}
            onValueChange={handleProductChange}
            placeholder="Seleccionar producto"
            searchPlaceholder="Buscar producto..."
            emptyMessage="No se encontraron productos."
          />
        )}

        {selectedProduct && !showNewProduct && (
          <div className="flex flex-col gap-2">
            {/* Row 1: Cantidad + Unidad */}
            <div className="grid grid-cols-2 gap-2">
              <div className="flex flex-col gap-1">
                <Label className="text-[10px] text-muted-foreground">Cantidad</Label>
                <NumericInput
                  min={0.0001}
                  step={1}
                  value={quantity}
                  onValueChange={(val) => setQuantity(Math.max(0.0001, val))}
                  className="bg-background border-border text-foreground"
                />
              </div>
              <div className="flex flex-col gap-1">
                <Label className="text-[10px] text-muted-foreground flex items-center gap-1">
                  <Ruler className="h-3 w-3" />
                  Unidad
                </Label>
                <Select value={unitId} onValueChange={setUnitId}>
                  <SelectTrigger className="bg-background border-border text-foreground h-10 text-sm">
                    <SelectValue placeholder="Base (×1)" />
                  </SelectTrigger>
                  <SelectContent className="bg-popover border-border">
                    <SelectItem value="">Sin unidad (base)</SelectItem>
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
            <div className="grid grid-cols-2 gap-2">
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
                <Label className="text-[10px] text-muted-foreground">Subtotal</Label>
                <div className="flex h-10 items-center justify-end rounded-md border border-border bg-background px-3 text-sm font-bold text-cyan-400 tabular-nums">
                  {formatMoney(stagedSubtotal)}
                </div>
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

      {/* ── Cart Items ──────────────────────────────────────────────────── */}
      {cartItems.length > 0 && (
        <CartItemList
          items={cartItems.map((item) => ({
            id: item.id,
            productName: item.productName,
            quantity: item.quantity,
            unitValue: item.unitCost,
            subtotal: item.subtotal,
            badge: item.unitSymbol ?? undefined,
          }))}
          onRemove={handleRemoveItem}
          onUpdateQty={handleUpdateQty}
          unitLabel="Costo unit."
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
              {formatMoney(cartTotal)}
            </span>
          </div>
        </div>
      )}

      {/* ── Date + Notes ────────────────────────────────────────────────── */}
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
      </div>

      {/* ── Submit ──────────────────────────────────────────────────────── */}
      <Button
        type="submit"
        className="w-full"
        disabled={submitting || cartItems.length === 0}
      >
        {submitting
          ? "Registrando..."
          : cartItems.length > 1
          ? `Confirmar compra (${cartItems.length} ítems)`
          : "Confirmar compra"}
      </Button>
    </form>
  )
}
