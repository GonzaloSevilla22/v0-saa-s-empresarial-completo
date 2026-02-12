"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { PRODUCT_CATEGORIES } from "@/lib/constants"
import { toast } from "sonner"

interface ProductFormProps {
  onSuccess: () => void
}

export function ProductForm({ onSuccess }: ProductFormProps) {
  const { addProduct } = useData()
  const [name, setName] = useState("")
  const [category, setCategory] = useState("")
  const [cost, setCost] = useState(0)
  const [price, setPrice] = useState(0)
  const [stock, setStock] = useState(0)
  const [minStock, setMinStock] = useState(10)

  const margin = price > 0 ? Math.round(((price - cost) / price) * 100) : 0

  function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name || !category) {
      toast.error("Completa nombre y categoria")
      return
    }
    addProduct({ name, category, cost, price, margin, stock, minStock })
    toast.success("Producto creado")
    onSuccess()
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Nombre</Label>
        <Input value={name} onChange={(e) => setName(e.target.value)} placeholder="Nombre del producto" className="bg-background border-border text-foreground" />
      </div>

      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Categoria</Label>
        <Select value={category} onValueChange={setCategory}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccionar categoria" />
          </SelectTrigger>
          <SelectContent className="bg-popover border-border">
            {PRODUCT_CATEGORIES.map((c) => (
              <SelectItem key={c} value={c}>{c}</SelectItem>
            ))}
          </SelectContent>
        </Select>
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Costo</Label>
          <Input type="number" min={0} step={0.01} value={cost} onChange={(e) => setCost(parseFloat(e.target.value) || 0)} className="bg-background border-border text-foreground" />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Precio</Label>
          <Input type="number" min={0} step={0.01} value={price} onChange={(e) => setPrice(parseFloat(e.target.value) || 0)} className="bg-background border-border text-foreground" />
        </div>
      </div>

      {price > 0 && (
        <div className="rounded-lg border border-border bg-accent/50 p-3 text-center">
          <span className="text-xs text-muted-foreground">Margen: </span>
          <span className={`text-sm font-bold ${margin >= 50 ? "text-emerald-400" : margin >= 30 ? "text-yellow-400" : "text-red-400"}`}>
            {margin}%
          </span>
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Stock inicial</Label>
          <Input type="number" min={0} value={stock} onChange={(e) => setStock(parseInt(e.target.value) || 0)} className="bg-background border-border text-foreground" />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Stock minimo</Label>
          <Input type="number" min={0} value={minStock} onChange={(e) => setMinStock(parseInt(e.target.value) || 0)} className="bg-background border-border text-foreground" />
        </div>
      </div>

      <Button type="submit" className="w-full">
        Crear producto
      </Button>
    </form>
  )
}
