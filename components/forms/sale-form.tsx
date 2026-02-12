"use client"

import { useState, useMemo } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { toast } from "sonner"

interface SaleFormProps {
  onSuccess: () => void
}

export function SaleForm({ onSuccess }: SaleFormProps) {
  const { products, clients, addSale } = useData()
  const [productId, setProductId] = useState("")
  const [clientId, setClientId] = useState("")
  const [quantity, setQuantity] = useState(1)

  const selectedProduct = useMemo(() => products.find((p) => p.id === productId), [products, productId])
  const selectedClient = useMemo(() => clients.find((c) => c.id === clientId), [clients, clientId])
  const total = selectedProduct ? selectedProduct.price * quantity : 0

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!selectedProduct || !selectedClient) {
      toast.error("Selecciona producto y cliente")
      return
    }
    addSale({
      date: new Date().toISOString().split("T")[0],
      productId: selectedProduct.id,
      productName: selectedProduct.name,
      clientId: selectedClient.id,
      clientName: selectedClient.name,
      quantity,
      unitPrice: selectedProduct.price,
      total,
    })
    toast.success("Venta registrada")
    onSuccess()
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Producto</Label>
        <Select value={productId} onValueChange={setProductId}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar producto" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {products.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                {p.name} - ${p.price} (Stock: {p.stock})
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Cliente</Label>
        <Select value={clientId} onValueChange={setClientId}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar cliente" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {clients.map((c) => (
              <SelectItem key={c.id} value={c.id}>
                {c.name}
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Cantidad</Label>
        <Input
          type="number"
          min={1}
          max={selectedProduct?.stock || 999}
          value={quantity}
          onChange={(e) => setQuantity(Math.max(1, parseInt(e.target.value) || 1))}
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="rounded-lg border border-border bg-accent/50 p-3">
        <div className="flex items-center justify-between text-sm">
          <span className="text-muted-foreground">Total</span>
          <span className="text-lg font-bold text-primary">${total.toLocaleString()}</span>
        </div>
      </div>

      <Button type="submit" className="w-full">
        Registrar venta
      </Button>
    </form>
  )
}
