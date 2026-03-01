"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useData } from "@/contexts/data-context"
import { PRODUCT_CATEGORIES } from "@/lib/constants"
import { toast } from "sonner"

import type { Product } from "@/lib/types"
import { Barcode, Fingerprint } from "lucide-react"

interface ProductFormProps {
  onSuccess: () => void
  initialData?: Product
}

export function ProductForm({ onSuccess, initialData }: ProductFormProps) {
  const { addProduct, updateProduct, products } = useData()
  const [name, setName] = useState(initialData?.name || "")
  const [category, setCategory] = useState(initialData?.category || "")
  const [cost, setCost] = useState(initialData?.cost || 0)
  const [price, setPrice] = useState(initialData?.price || 0)
  const [stock, setStock] = useState(initialData?.stock || 0)
  const [minStock, setMinStock] = useState(initialData?.minStock || 10)
  const [barcode, setBarcode] = useState(initialData?.barcode || "")
  const [parentId, setParentId] = useState(initialData?.parentId || "none")

  const margin = price > 0 ? Math.round(((price - cost) / price) * 100) : 0

  const generateBarcode = () => {
    const code = Math.floor(Math.random() * 9000000000000) + 1000000000000
    setBarcode(code.toString())
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!name || (!category && parentId === "none")) {
      toast.error("Completá nombre y categoría")
      return
    }

    const productData = {
      name,
      category: parentId !== "none" ? (products.find(p => p.id === parentId)?.category || category) : category,
      cost,
      price,
      margin,
      stock,
      minStock,
      barcode,
      parentId: parentId === "none" ? undefined : parentId
    }

    try {
      if (initialData) {
        await updateProduct({ ...productData, id: initialData.id })
        toast.success("Producto actualizado")
      } else {
        await addProduct(productData)
        toast.success("Producto creado")
      }
      onSuccess()
    } catch (error) {
      toast.error("Error al guardar producto")
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Nombre</Label>
        <Input
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Ej: Remera AFA - Talle S"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Producto Padre (Variante)</Label>
          <Select value={parentId} onValueChange={setParentId}>
            <SelectTrigger className="bg-background border-border text-foreground">
              <SelectValue placeholder="Ninguno" />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border">
              <SelectItem value="none">Ninguno (Producto Base)</SelectItem>
              {products.filter(p => !p.parentId && p.id !== initialData?.id).map((p) => (
                <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Código de Barras</Label>
          <div className="flex gap-2">
            <Input
              value={barcode}
              onChange={(e) => setBarcode(e.target.value)}
              placeholder="Código"
              className="bg-background border-border text-foreground flex-1"
            />
            <Button type="button" variant="outline" size="icon" onClick={generateBarcode} title="Generar código">
              <Barcode className="h-4 w-4" />
            </Button>
          </div>
        </div>
      </div>

      {parentId === "none" && (
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Categoría</Label>
          <Select value={category} onValueChange={setCategory}>
            <SelectTrigger className="bg-background border-border text-foreground">
              <SelectValue placeholder="Seleccionar categoría" />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border">
              {PRODUCT_CATEGORIES.map((c) => (
                <SelectItem key={c} value={c}>{c}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      )}

      <div className="grid grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Costo</Label>
          <NumericInput min={0} step={0.01} value={cost} onValueChange={setCost} className="bg-background border-border text-foreground" />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Precio</Label>
          <NumericInput min={0} step={0.01} value={price} onValueChange={setPrice} className="bg-background border-border text-foreground" />
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
          <NumericInput min={0} value={stock} onValueChange={setStock} className="bg-background border-border text-foreground" />
        </div>
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Stock mínimo</Label>
          <NumericInput min={0} value={minStock} onValueChange={setMinStock} className="bg-background border-border text-foreground" />
        </div>
      </div>

      <Button type="submit" className="w-full">
        {initialData ? "Actualizar producto" : "Crear producto"}
      </Button>
    </form>
  )
}
