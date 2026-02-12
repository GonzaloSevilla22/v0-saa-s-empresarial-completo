"use client"

import { useState, useMemo } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { toast } from "sonner"

interface PurchaseFormProps {
  onSuccess: () => void
}

export function PurchaseForm({ onSuccess }: PurchaseFormProps) {
  const { products, addPurchase } = useData()
  const [productId, setProductId] = useState("")
  const [quantity, setQuantity] = useState(1)
  const [unitCost, setUnitCost] = useState(0)

  const selectedProduct = useMemo(() => products.find((p) => p.id === productId), [products, productId])
  const total = unitCost * quantity

  function handleProductChange(id: string) {
    setProductId(id)
    const p = products.find((x) => x.id === id)
    if (p) setUnitCost(p.cost)
  }

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!selectedProduct) {
      toast.error("Selecciona un producto")
      return
    }
    addPurchase({
      date: new Date().toISOString().split("T")[0],
      productId: selectedProduct.id,
      productName: selectedProduct.name,
      quantity,
      unitCost,
      total,
    })
    toast.success("Compra registrada")
    onSuccess()
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Producto</Label>
        <Select value={productId} onValueChange={handleProductChange}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar producto" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {products.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.name} (Costo: ${p.cost})
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Cantidad</Label>
          <Input
            type="number"
            min={1}
            value={quantity}
            onChange={(e) => setQuantity(Math.max(1, parseInt(e.target.value) || 1))}
            className="bg-background border-border text-foreground"
          />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Costo unitario</Label>
          <Input
            type="number"
            min={0}
            step={0.01}
            value={unitCost}
            onChange={(e) => setUnitCost(parseFloat(e.target.value) || 0)}
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      <div className="rounded-lg border border-border bg-accent/50 p-3">
        <div className="flex items-center justify-between text-sm">
          <span className="text-muted-foreground">Total</span>
          <span className="text-lg font-bold text-primary">${total.toLocaleString()}</span>
        </div>
      </div>

      <Button type="submit" className="w-full">
        Registrar compra
      </Button>
    </form>
  )
}
