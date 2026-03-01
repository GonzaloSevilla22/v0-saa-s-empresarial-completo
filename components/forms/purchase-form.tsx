"use client"

import { useState, useMemo } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { formatMoney } from "@/lib/format"
import { PRODUCT_CATEGORIES } from "@/lib/constants"
import { Plus, PackagePlus } from "lucide-react"
import { toast } from "sonner"

interface PurchaseFormProps {
  onSuccess: () => void
}

export function PurchaseForm({ onSuccess }: PurchaseFormProps) {
  const { products, addPurchase, addProduct } = useData()
  const [productId, setProductId] = useState("")
  const [quantity, setQuantity] = useState(1)
  const [unitCost, setUnitCost] = useState(0)

  // Inline new product
  const [showNewProduct, setShowNewProduct] = useState(false)
  const [newProductName, setNewProductName] = useState("")
  const [newProductCategory, setNewProductCategory] = useState("")
  const [newProductCost, setNewProductCost] = useState(0)
  const [newProductPrice, setNewProductPrice] = useState(0)
  const [newProductMinStock, setNewProductMinStock] = useState(10)

  const [description, setDescription] = useState("")

  const selectedProduct = useMemo(() => products.find((p) => p.id === productId), [products, productId])
  const total = unitCost * quantity

  function handleProductChange(id: string) {
    setProductId(id)
    const p = products.find((x) => x.id === id)
    if (p) {
      setUnitCost(p.cost)
      setDescription("") // Reset or leave? Leave for now or set to "Compra de [product]"
    }
  }

  function handleCreateProduct() {
    if (!newProductName.trim() || !newProductCategory) {
      toast.error("Nombre y categoría son obligatorios")
      return
    }
    const margin = newProductPrice > 0 ? Math.round(((newProductPrice - newProductCost) / newProductPrice) * 100) : 0
    addProduct({
      name: newProductName,
      category: newProductCategory,
      cost: newProductCost,
      price: newProductPrice,
      margin,
      stock: 0,
      minStock: newProductMinStock,
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
    if (!selectedProduct) {
      toast.error("Seleccioná un producto")
      return
    }
    try {
      await addPurchase({
        date: new Date().toISOString().split("T")[0],
        productId: selectedProduct.id,
        productName: selectedProduct.name,
        quantity,
        unitCost,
        total,
        description: description || `Compra de ${selectedProduct.name}`,
      })
      toast.success("Compra registrada")
      onSuccess()
    } catch (error: any) {
      console.error("Purchase creation error:", error)
      const errorMsg = error.message || (typeof error === 'string' ? error : "Error desconocido")
      toast.error(`Error al registrar compra: ${errorMsg}`)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <div className="flex items-center justify-between">
          <Label className="text-foreground">Producto</Label>
          <Button
            type="button"
            variant="ghost"
            size="sm"
            className="h-6 text-xs text-primary"
            onClick={() => setShowNewProduct(!showNewProduct)}
          >
            <PackagePlus className="h-3 w-3 mr-1" />
            {showNewProduct ? "Cancelar" : "Nuevo producto"}
          </Button>
        </div>

        {showNewProduct ? (
          <div className="rounded-lg border border-border bg-accent/30 p-3 flex flex-col gap-2">
            <Input
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
                  <SelectItem key={c} value={c}>{c}</SelectItem>
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
                <Label className="text-[10px] text-muted-foreground">Stock min.</Label>
                <NumericInput
                  min={0}
                  value={newProductMinStock}
                  onValueChange={setNewProductMinStock}
                  className="bg-background border-border text-foreground text-sm"
                />
              </div>
            </div>
            <Button type="button" size="sm" variant="secondary" onClick={handleCreateProduct} className="w-full">
              <Plus className="h-3 w-3 mr-1" />
              Crear y seleccionar
            </Button>
          </div>
        ) : (
          <Select value={productId} onValueChange={handleProductChange}>
            <SelectTrigger className="bg-background border-border text-foreground">
              <SelectValue placeholder="Seleccionar producto" />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border">
              {products.map((p) => (
                <SelectItem key={p.id} value={p.id}>
                  {p.name} (Costo: {formatMoney(p.cost)})
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        )}
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Cantidad</Label>
          <NumericInput
            min={1}
            value={quantity}
            onValueChange={(val) => setQuantity(Math.max(1, val))}
            className="bg-background border-border text-foreground"
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Costo unitario</Label>
          <NumericInput
            min={0}
            step={0.01}
            value={unitCost}
            onValueChange={setUnitCost}
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Notas / Descripción (Opcional)</Label>
        <Input
          value={description}
          onChange={(e) => setDescription(e.target.value)}
          placeholder="Ej: Lote vencimiento Dic 2026"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="rounded-lg border border-border bg-accent/50 p-3">
        <div className="flex items-center justify-between text-sm">
          <span className="text-muted-foreground">Total</span>
          <span className="text-lg font-bold text-primary">{formatMoney(total)}</span>
        </div>
      </div>

      <Button type="submit" className="w-full">
        Registrar compra
      </Button>
    </form>
  )
}
