"use client"

import { useState, useMemo, useCallback } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useProducts } from "@/hooks/data/use-products"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { ProductCategorySelect } from "@/components/product-categories/ProductCategorySelect"
import { useBarcodeScanner } from "@/hooks/use-barcode-scanner"
import { generateEAN13 } from "@/lib/barcode-utils"
import { cn } from "@/lib/utils"
import { toast } from "sonner"

import type { Product, StockControlType } from "@/lib/types"
import { Barcode, Package, Wrench, ScanLine, X } from "lucide-react"

interface ProductFormProps {
  onSuccess: () => void
  initialData?: Product
  /** Pre-select a parent when creating a new variant (does not trigger edit mode) */
  defaultParentId?: string
}

export function ProductForm({ onSuccess, initialData, defaultParentId }: ProductFormProps) {
  const { addProduct, updateProduct, products } = useProducts()
  const { units } = useUnitsOfMeasure()

  const [name, setName] = useState(initialData?.name || "")
  // productos-categorias-sku (D1): la categoría se elige del catálogo de la
  // cuenta por id — PRODUCT_CATEGORIES (lista fija) se retiró.
  const [categoryId, setCategoryId] = useState<string | null>(initialData?.categoryId ?? null)
  const [cost, setCost] = useState(initialData?.cost || 0)
  const [price, setPrice] = useState(initialData?.price || 0)
  const [stock, setStock] = useState(initialData?.stock || 0)
  const [minStock, setMinStock] = useState(initialData?.minStock || 10)
  const [barcode, setBarcode] = useState(initialData?.barcode || "")
  // productos-categorias-sku: SKU opcional, visible por primera vez en el
  // formulario. Se recorta al enviar; vacío → undefined (NULL en la base).
  const [sku, setSku] = useState(initialData?.sku || "")
  const [parentId, setParentId] = useState(initialData?.parentId || defaultParentId || "none")

  // ── Etapa 6 fields ──────────────────────────────────────────────────────────
  const [stockControlType, setStockControlType] = useState<StockControlType>(
    // parent catalogue entries stay 'variant_only'; never let the form downgrade them
    initialData?.stockControlType ?? "tracked",
  )
  const [baseUnitId, setBaseUnitId] = useState(initialData?.baseUnitId ?? "")

  const [isScanning, setIsScanning] = useState(false)

  const margin = price > 0 ? Math.round(((price - cost) / price) * 100) : 0

  const isVariant = parentId !== "none"

  // ── Scanner integration ──────────────────────────────────────────────────────
  const handleScanComplete = useCallback((code: string) => {
    setBarcode(code)
    setIsScanning(false)
    toast.success(`Código escaneado: ${code}`)
  }, [])

  useBarcodeScanner({ onScan: handleScanComplete, enabled: isScanning })

  // ── Units grouped by type for the selector ──────────────────────────────────
  const unitGroups = useMemo(() => {
    const groupMap = new Map<string, typeof units>()
    for (const u of units) {
      const arr = groupMap.get(u.type) ?? []
      arr.push(u)
      groupMap.set(u.type, arr)
    }
    return groupMap
  }, [units])

  const typeLabels: Record<string, string> = {
    unit: "Unidades",
    weight: "Peso",
    volume: "Volumen",
    length: "Longitud",
    custom: "Personalizadas",
  }

  const generateBarcode = () => {
    setBarcode(generateEAN13())
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    // Regla vigente (intacta): categoría obligatoria salvo variante — la
    // variante hereda la del padre (D11), resuelta en el servidor.
    if (!name || (!categoryId && parentId === "none")) {
      toast.error("Completá nombre y categoría")
      return
    }

    const resolvedParentId = parentId === "none" ? undefined : parentId
    const parent = resolvedParentId ? products.find((p) => p.id === resolvedParentId) : undefined
    const productData = {
      name,
      // El TEXT `category` lo mantiene el trigger de espejo desde category_id;
      // para la variante se acarrea el del padre (camino legacy de lectura).
      category: parent?.category ?? "",
      // Variante: NO se manda categoryId — el servidor la hereda del padre e
      // ignora lo que mande el cliente (D11/9.7).
      categoryId: resolvedParentId ? undefined : (categoryId ?? undefined),
      cost,
      price,
      margin,
      stock: stockControlType === "untracked" ? 0 : stock,
      minStock: stockControlType === "untracked" ? 0 : minStock,
      barcode,
      sku: sku.trim() || undefined,
      parentId: resolvedParentId,
      // is_variant is derived from whether a parent is assigned
      isVariant: resolvedParentId !== undefined,
      // ── Etapa 6 ──────────────────────────────────────────────────────────────
      stockControlType: isVariant
        ? "tracked"       // variants always tracked individually
        : stockControlType,
      baseUnitId:
        !isVariant && stockControlType === "tracked" && baseUnitId
          ? baseUnitId
          : undefined,
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
    } catch (error: unknown) {
      // productos-categorias-sku (D5): el 409 de SKU (y cualquier detail del
      // backend) se muestra tal cual; el formulario conserva lo cargado.
      const msg = error instanceof Error && error.message ? error.message : "Error al guardar producto"
      toast.error(msg)
    }
  }

  return (
    <form onSubmit={handleSubmit} className="flex flex-col gap-4">
      <div className="flex flex-col gap-2">
        <Label className="text-foreground">Nombre</Label>
        <Input
          selectOnFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          placeholder="Ej: Remera AFA - Talle S"
          className="bg-background border-border text-foreground"
        />
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Producto Padre (Variante)</Label>
          <Select value={parentId} onValueChange={setParentId}>
            <SelectTrigger className="bg-background border-border text-foreground">
              <SelectValue placeholder="Ninguno" />
            </SelectTrigger>
            <SelectContent className="bg-popover border-border">
              <SelectItem value="none">Ninguno (Producto Base)</SelectItem>
              {products.filter((p) => !p.parentId && p.id !== initialData?.id).map((p) => (
                <SelectItem key={p.id} value={p.id}>{p.name}</SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>

        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Código de Barras</Label>
          <div className="flex gap-2">
            <Input
              selectOnFocus
              value={barcode}
              onChange={(e) => setBarcode(e.target.value)}
              placeholder={isScanning ? "Escanee el código..." : "Código"}
              className={cn(
                "bg-background border-border text-foreground flex-1",
                isScanning && "ring-2 ring-primary border-primary animate-pulse",
              )}
            />
            <Button
              type="button"
              variant={isScanning ? "default" : "outline"}
              size="icon"
              onClick={() => setIsScanning((s) => !s)}
              title={isScanning ? "Cancelar escaneo" : "Escanear con lector"}
            >
              {isScanning ? <X className="h-4 w-4" /> : <ScanLine className="h-4 w-4" />}
            </Button>
            <Button type="button" variant="outline" size="icon" onClick={generateBarcode} title="Generar EAN-13 válido">
              <Barcode className="h-4 w-4" />
            </Button>
          </div>
          {isScanning && (
            <p className="text-[11px] text-primary animate-pulse">
              Apunte el lector al código de barras...
            </p>
          )}
        </div>
      </div>

      {/* ── Categoría (sólo producto base) + SKU opcional ─────────────────── */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        {parentId === "none" && (
          <ProductCategorySelect value={categoryId} onChange={setCategoryId} />
        )}
        <div className="flex flex-col gap-2">
          <Label htmlFor="product-sku" className="text-foreground">
            SKU <span className="text-muted-foreground font-normal">(opcional)</span>
          </Label>
          <Input
            id="product-sku"
            selectOnFocus
            value={sku}
            onChange={(e) => setSku(e.target.value)}
            placeholder="Ej: REM-001"
            className="bg-background border-border text-foreground"
          />
        </div>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
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

      {/* ── Stock control type + unit (standalone products only) ─────────────── */}
      {!isVariant && (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Tipo de inventario</Label>
            <Select
              value={stockControlType === "variant_only" ? "tracked" : stockControlType}
              onValueChange={(v) => setStockControlType(v as StockControlType)}
            >
              <SelectTrigger className="bg-background border-border text-foreground">
                <SelectValue />
              </SelectTrigger>
              <SelectContent className="bg-popover border-border">
                <SelectItem value="tracked">
                  <span className="flex items-center gap-1.5">
                    <Package className="h-3.5 w-3.5 text-primary" />
                    Inventario físico
                  </span>
                </SelectItem>
                <SelectItem value="untracked">
                  <span className="flex items-center gap-1.5">
                    <Wrench className="h-3.5 w-3.5 text-muted-foreground" />
                    Servicio / Digital
                  </span>
                </SelectItem>
              </SelectContent>
            </Select>
          </div>

          {stockControlType === "tracked" && units.length > 0 && (
            <div className="flex flex-col gap-2">
              <Label className="text-foreground">Unidad de medida</Label>
              <Select value={baseUnitId} onValueChange={setBaseUnitId}>
                <SelectTrigger className="bg-background border-border text-foreground">
                  <SelectValue placeholder="Seleccionar unidad" />
                </SelectTrigger>
                <SelectContent className="bg-popover border-border max-h-56">
                  {Array.from(unitGroups.entries()).map(([type, groupUnits]) => (
                    <div key={type}>
                      <div className="px-2 py-1 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
                        {typeLabels[type] ?? type}
                      </div>
                      {groupUnits.map((u) => (
                        <SelectItem key={u.id} value={u.id}>
                          {u.name} <span className="text-muted-foreground">({u.symbol})</span>
                        </SelectItem>
                      ))}
                    </div>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}
        </div>
      )}

      {/* ── Stock fields (only for tracked products) ──────────────────────────── */}
      {stockControlType !== "untracked" && (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Stock inicial</Label>
            <NumericInput min={0} value={stock} onValueChange={setStock} className="bg-background border-border text-foreground" />
          </div>
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Stock mínimo</Label>
            <NumericInput min={0} value={minStock} onValueChange={setMinStock} className="bg-background border-border text-foreground" />
          </div>
        </div>
      )}

      <Button type="submit" className="w-full">
        {initialData ? "Actualizar producto" : "Crear producto"}
      </Button>
    </form>
  )
}
