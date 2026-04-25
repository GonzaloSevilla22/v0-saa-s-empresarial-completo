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
import { formatMoney, CURRENCIES, type Currency } from "@/lib/format"
import {
  generateOperationId,
  calcSaleSubtotal,
  calcCartTotal,
  type SaleCartItem,
} from "@/lib/cart-utils"
import { Plus, UserPlus, ShoppingCart, PackagePlus } from "lucide-react"
import { toast } from "sonner"

interface SaleFormProps {
  onSuccess: () => void
}

export function SaleForm({ onSuccess }: SaleFormProps) {
  const { products, clients, addSale, addClient, refreshData } = useData()

  // ── Cart state ──────────────────────────────────────────────────────────────
  const [cartItems, setCartItems] = useState<SaleCartItem[]>([])

  // ── Current item being staged ───────────────────────────────────────────────
  const [productId, setProductId] = useState("")
  const [quantity, setQuantity] = useState(1)
  const [discount, setDiscount] = useState(0)

  // ── Header fields (apply to all items) ─────────────────────────────────────
  const [clientId, setClientId] = useState("")
  const [currency, setCurrency] = useState<Currency>("ARS")

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
  const cartTotal = useMemo(() => calcCartTotal(cartItems), [cartItems])
  const stagedSubtotal = useMemo(
    () => (selectedProduct ? calcSaleSubtotal(selectedProduct.price, quantity, discount) : 0),
    [selectedProduct, quantity, discount],
  )

  // ── Option lists ────────────────────────────────────────────────────────────

  // IDs of products that are "parent catalogue entries" (have at least one variant child).
  // These must NOT appear in the sale dropdown — users must pick a specific variant.
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
            label: `${displayName} — ${formatMoney(p.price)} (Stock: ${p.stock})`,
          }
        }),
    [products, parentProductIds, productById],
  )
  const clientOptions = useMemo(
    () => clients.map((c) => ({ value: c.id, label: c.name })),
    [clients],
  )

  // ── Handlers ────────────────────────────────────────────────────────────────

  function handleAddToCart() {
    if (!selectedProduct) {
      toast.error("Seleccioná un producto")
      return
    }
    const existing = cartItems.find((item) => item.productId === productId)
    if (existing) {
      const newQty = existing.quantity + quantity
      if (newQty > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${selectedProduct.stock})`)
        return
      }
      setCartItems((prev) =>
        prev.map((item) =>
          item.productId === productId
            ? {
                ...item,
                quantity: newQty,
                subtotal: calcSaleSubtotal(selectedProduct.price, newQty, item.discount),
              }
            : item,
        ),
      )
      toast.success(`Cantidad actualizada: ${selectedProduct.name}`)
    } else {
      if (quantity > selectedProduct.stock) {
        toast.error(`Stock insuficiente (disponible: ${selectedProduct.stock})`)
        return
      }
      setCartItems((prev) => [
        ...prev,
        {
          id: crypto.randomUUID(),
          productId: selectedProduct.id,
          productName: selectedProduct.name,
          unitPrice: selectedProduct.price,
          quantity,
          discount,
          subtotal: stagedSubtotal,
        },
      ])
      toast.success(`${selectedProduct.name} agregado`)
    }
    // Reset staged item
    setProductId("")
    setQuantity(1)
    setDiscount(0)
  }

  function handleRemoveItem(id: string) {
    setCartItems((prev) => prev.filter((item) => item.id !== id))
  }

  function handleUpdateQty(id: string, qty: number) {
    setCartItems((prev) =>
      prev.map((item) => {
        if (item.id !== id) return item
        const newQty = Math.max(1, qty)
        return {
          ...item,
          quantity: newQty,
          subtotal: calcSaleSubtotal(item.unitPrice, newQty, item.discount),
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
      name: newClientName,
      email: newClientEmail,
      phone: newClientPhone,
      status: "activo",
      lastPurchase: "-",
      totalSpent: 0,
    })
    toast.success(`Cliente "${newClientName}" creado`)
    setShowNewClient(false)
    setNewClientName("")
    setNewClientEmail("")
    setNewClientPhone("")
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!selectedClient) {
      toast.error("Seleccioná un cliente")
      return
    }
    if (cartItems.length === 0) {
      toast.error("Agregá al menos un producto al carrito")
      return
    }

    setSubmitting(true)
    const operationId = generateOperationId()
    const date = new Date().toISOString().split("T")[0]

    type Result = { success: boolean; productName: string; error?: string }
    const results: Result[] = []

    for (const item of cartItems) {
      try {
        const effectiveUnitPrice = item.unitPrice * (1 - item.discount / 100)
        await addSale({
          date,
          productId: item.productId,
          productName: item.productName,
          clientId: selectedClient.id,
          clientName: selectedClient.name,
          quantity: item.quantity,
          unitPrice: effectiveUnitPrice,
          total: item.subtotal,
          currency,
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
      // Partial success — keep dialog open so user can see what failed
      toast.warning(`⚠️ ${successful.length} registrado(s), ${failed.length} con error`)
      failed.forEach((f) => toast.error(`❌ ${f.productName}: ${f.error}`))
      await refreshData()
      // Remove successfully submitted items from cart
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
      {/* ── Header: Cliente + Moneda ─────────────────────────────────────── */}
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
                value={newClientName}
                onChange={(e) => setNewClientName(e.target.value)}
                placeholder="Nombre del cliente"
                className="bg-background border-border text-foreground text-sm"
              />
              <div className="grid grid-cols-1 sm:grid-cols-2 gap-2">
                <Input
                  value={newClientEmail}
                  onChange={(e) => setNewClientEmail(e.target.value)}
                  placeholder="Email (opcional)"
                  className="bg-background border-border text-foreground text-sm"
                />
                <Input
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
      </div>

      <div className="border-t border-border" />

      {/* ── Product Adder ───────────────────────────────────────────────── */}
      <div className="flex flex-col gap-3 rounded-lg border border-dashed border-border bg-accent/15 p-3">
        <Label className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground flex items-center gap-1.5">
          <PackagePlus className="h-3.5 w-3.5" />
          Agregar producto
        </Label>

        <SearchableSelect
          options={productOptions}
          value={productId}
          onValueChange={(id) => {
            setProductId(id)
            setQuantity(1)
            setDiscount(0)
          }}
          placeholder="Seleccionar producto"
          searchPlaceholder="Buscar producto..."
          emptyMessage="No se encontraron productos."
        />

        {selectedProduct && (
          <div className="grid grid-cols-3 gap-2">
            <div className="flex flex-col gap-1">
              <Label className="text-[10px] text-muted-foreground">Cantidad</Label>
              <NumericInput
                min={1}
                max={selectedProduct.stock || 9999}
                value={quantity}
                onValueChange={(val) => setQuantity(Math.max(1, val))}
                className="bg-background border-border text-foreground"
              />
            </div>
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
            id: item.id,
            productName: item.productName,
            quantity: item.quantity,
            unitValue: item.unitPrice,
            subtotal: item.subtotal,
            badge: item.discount > 0 ? `${item.discount}% desc.` : undefined,
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
          ? "Registrando..."
          : cartItems.length > 1
          ? `Confirmar venta (${cartItems.length} ítems)`
          : "Confirmar venta"}
      </Button>
    </form>
  )
}
