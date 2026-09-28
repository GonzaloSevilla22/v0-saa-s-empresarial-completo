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
import { PythonApiError } from "@/lib/api/python-api-error"
import { toast } from "sonner"
import { useScaleSettings } from "@/hooks/data/use-scale-settings"
import { decodeScaleBarcode } from "@/lib/scale-barcode"
import { isProductoPorUnidades } from "@/lib/unit-utils"

import type { Product, StockControlType } from "@/lib/types"
import { Barcode, Package, Wrench, ScanLine, X } from "lucide-react"

/**
 * ventas-unidades-conversion (decisión 7, OK del PO 2026-09-27): valor del
 * selector para la opción explícita "Sin unidad". Radix no admite un
 * `SelectItem` con `value=""` (el vacío queda reservado para el placeholder
 * "Seleccionar unidad", que significa "no lo toqué"); los ids de unidad son
 * uuid, así que el centinela no colisiona.
 */
const NO_BASE_UNIT = "none"

/**
 * El backend rechazó el cambio de unidad base por D11/D-C: el guard del
 * service responde `code: "base_unit_locked"`; si la carrera la gana otro
 * escritor, el trigger `trg_product_base_unit_guard` llega como P0409 con el
 * token al principio del `detail`.
 */
const BASE_UNIT_LOCKED_CODE = "base_unit_locked"
function isBaseUnitLockedError(error: unknown): boolean {
  if (error instanceof PythonApiError && error.code === BASE_UNIT_LOCKED_CODE) return true
  return error instanceof Error && error.message.startsWith(`${BASE_UNIT_LOCKED_CODE}:`)
}

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
  // productos-costo-nullable: `cost` es OPCIONAL — `null` = sin costo
  // cargado (alta nueva sin tocar el campo, o un producto existente sin
  // costo), nunca 0 por default. `costTouched` distingue "no lo toqué" de
  // "lo dejé en el mismo valor" para el tri-estado de la edición (D12,
  // mismo molde que sku/category_id): la clave `cost` sólo viaja en el
  // payload de EDICIÓN si el usuario tocó el campo.
  const [cost, setCost] = useState<number | null>(initialData?.cost ?? null)
  const [costTouched, setCostTouched] = useState(false)
  const [price, setPrice] = useState(initialData?.price || 0)
  const [stock, setStock] = useState(initialData?.stock || 0)
  // Corrección del PR #584: `??`, no `||` — un mínimo 0 ("sin alerta", RN-23)
  // es un valor, no un vacío; el 10 queda sólo como default de un alta nueva.
  const [minStock, setMinStock] = useState(initialData?.minStock ?? 10)
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

  // balanza-etiquetas-pos (D2, D13): tri-estado igual que cost/baseUnitId —
  // `scalePluTouched` distingue "no lo toqué" (conserva en la edición) de
  // "lo dejé en null" (desasigna). En un alta la clave siempre viaja.
  const [scalePlu, setScalePlu] = useState<number | null>(initialData?.scalePlu ?? null)
  const [scalePluTouched, setScalePluTouched] = useState(false)
  const [scalePluError, setScalePluError] = useState<string | null>(null)

  const [isScanning, setIsScanning] = useState(false)

  // balanza-etiquetas-pos (D6): la lectura de configuración es la de la
  // cuenta TAL CUAL (sin forzar `enabled`, a diferencia del probador de la
  // pestaña Balanza — acá es sólo un aviso, no una confirmación previa).
  const { settings: scaleSettings } = useScaleSettings()
  const scaleBarcodeWarning = useMemo(() => {
    if (!barcode.trim()) return null
    const decoded = decodeScaleBarcode(barcode.trim(), scaleSettings)
    if (decoded.status !== "ok") return null
    return "Esto es una etiqueta de balanza; asigná el PLU en \"Código de balanza\" en vez de usar este código de barras."
  }, [barcode, scaleSettings])

  // balanza-etiquetas-pos (D2/D12): aviso no bloqueante si el PLU tiene más
  // dígitos que el campo "Código" del formato de venta habilitado que le
  // corresponde (peso/unidad, según la unidad base elegida) — no entraría en
  // la etiqueta que exporta el catálogo (D12).
  const scalePluDigitsWarning = useMemo(() => {
    if (scalePlu == null) return null
    const unit = units.find((u) => u.id === baseUnitId)
    const relevantKind = unit?.type === "weight" ? "weighed" : isProductoPorUnidades(unit) ? "unit" : null
    if (!relevantKind) return null
    const layout = scaleSettings.layouts.find((l) => l.kind === relevantKind && l.enabled)
    const pluSegment = layout?.segments.find((s) => s.field === "plu")
    if (!pluSegment) return null
    const maxPlu = 10 ** pluSegment.digits - 1
    if (scalePlu <= maxPlu) return null
    return `El PLU ${scalePlu} tiene más dígitos que el campo Código del formato configurado (máximo ${maxPlu}) — no entraría en la etiqueta.`
  }, [scalePlu, units, baseUnitId, scaleSettings])

  // productos-costo-nullable: sin costo, el margen es ausente — nunca 0 ni
  // un valor derivado de un costo inventado (capability product-cost).
  const margin = cost == null ? null : (price > 0 ? Math.round(((price - cost) / price) * 100) : 0)

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
    const productData = {
      name,
      // productos-categoria-text-retiro: `category` ya no se deriva del padre
      // acá — category_id es la única fuente de verdad y el nombre legible lo
      // deriva el servidor (v_products_with_stock). El campo sigue existiendo
      // en el tipo `Product` (D1/D2, no cambia) pero este valor nunca se
      // transmite: use-products.ts ya no lo incluye en el payload de alta/edición.
      category: "",
      // Variante: NO se manda categoryId — el servidor la hereda del padre e
      // ignora lo que mande el cliente (D11/9.7).
      categoryId: resolvedParentId ? undefined : (categoryId ?? undefined),
      // productos-costo-nullable (D12, tri-estado): en una EDICIÓN, la clave
      // `cost` sólo viaja si el usuario tocó el campo — así se conserva el
      // costo existente sin reescribirlo en cada guardado. En un ALTA
      // siempre viaja (ausencia y `null` explícito producen el mismo
      // resultado en la creación, así que no hace falta distinguir).
      ...(!initialData || costTouched ? { cost } : {}),
      price,
      margin,
      stock: stockControlType === "untracked" ? 0 : stock,
      minStock: stockControlType === "untracked" ? 0 : minStock,
      barcode,
      sku: sku.trim() || undefined,
      // balanza-etiquetas-pos (D2/D13): mismo tri-estado que cost — en un
      // alta la clave siempre viaja; en una edición sólo si se tocó.
      ...(!initialData || scalePluTouched ? { scalePlu } : {}),
      parentId: resolvedParentId,
      // is_variant is derived from whether a parent is assigned
      isVariant: resolvedParentId !== undefined,
      // ── Etapa 6 ──────────────────────────────────────────────────────────────
      stockControlType: isVariant
        ? "tracked"       // variants always tracked individually
        : stockControlType,
      // ventas-unidades-conversion (auditoría post-apply): una variante hereda
      // la base del padre (nunca declara la propia); para un padre variant_only
      // o un producto no rastreado el selector no se muestra, así que se manda
      // `undefined` = "sin cambios" (el hook omite el campo en la edición y el
      // backend conserva el valor; en el alta viaja null). Sin la condición
      // "tracked", elegir kg y pasar a Servicio / Digital guardaba una unidad
      // que el usuario ya no ve (corrección del PR #584).
      // Decisión 7: "Sin unidad" manda `null` explícito = desasignar (en el
      // alta es lo mismo que no elegir); el selector sin tocar sigue en
      // `undefined`. Quitarla con stock o historia la rechaza el backend
      // (D11/D-C, 409 base_unit_locked).
      baseUnitId:
        isVariant || stockControlType !== "tracked" || !baseUnitId
          ? undefined
          : baseUnitId === NO_BASE_UNIT
            ? null
            : baseUnitId,
    }

    setScalePluError(null)
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
      // Decisión 7: la unidad base NO cambió (el producto tiene stock o
      // historia) — el selector vuelve a la que conserva, así lo que se ve es
      // lo que quedó guardado y el resto de lo cargado se puede reintentar.
      if (isBaseUnitLockedError(error)) setBaseUnitId(initialData?.baseUnitId ?? "")
      // balanza-etiquetas-pos (D2): 409 scale_plu_taken / 422 scale_plu_parent
      // — el `field` del problem+json lo distingue de cualquier otro error.
      if (error instanceof PythonApiError && error.field === "scale_plu") {
        setScalePluError(error.message)
      }
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
          {/* balanza-etiquetas-pos (D6): aviso no bloqueante — este código
              es una etiqueta de balanza, no un código de barras común. */}
          {scaleBarcodeWarning && (
            <p className="text-[11px] text-yellow-500">{scaleBarcodeWarning}</p>
          )}
        </div>
      </div>

      {/* ── Código de balanza (PLU) — balanza-etiquetas-pos (D2) ─────────────
          Oculto para un producto padre (variant_only): el PLU se asigna a
          cada variante, nunca al padre (CHECK products_scale_plu_not_parent). */}
      {stockControlType !== "variant_only" && (
        <div className="flex flex-col gap-2">
          <Label htmlFor="product-scale-plu" className="text-foreground">
            Código de balanza (PLU) <span className="text-muted-foreground font-normal">(opcional)</span>
          </Label>
          <NumericInput
            id="product-scale-plu"
            nullable
            min={1}
            max={999999}
            step={1}
            value={scalePlu}
            onValueChange={(v) => {
              setScalePlu(v == null ? null : Math.trunc(v))
              setScalePluTouched(true)
              setScalePluError(null)
            }}
            className="bg-background border-border text-foreground"
          />
          <p className="text-[11px] text-muted-foreground">
            El código de PLU que la balanza imprime en la etiqueta (Configuración → Balanza).
          </p>
          {scalePluDigitsWarning && (
            <p className="text-[11px] text-yellow-500">{scalePluDigitsWarning}</p>
          )}
          {scalePluError && <p className="text-[11px] text-destructive">{scalePluError}</p>}
        </div>
      )}

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
          <Label htmlFor="product-cost" className="text-foreground">Costo</Label>
          <NumericInput
            id="product-cost"
            nullable
            min={0}
            step={0.01}
            value={cost}
            onValueChange={(v) => { setCost(v); setCostTouched(true) }}
            className="bg-background border-border text-foreground"
          />
          {/* productos-costo-nullable (D15): el precedente exacto es la ayuda
              de SKU de arriba — un campo opcional se declara como tal. */}
          <p className="text-[11px] text-muted-foreground">
            Dejalo vacío si todavía no sabés el costo.
          </p>
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="product-price" className="text-foreground">Precio</Label>
          <NumericInput id="product-price" min={0} step={0.01} value={price} onValueChange={setPrice} className="bg-background border-border text-foreground" />
        </div>
      </div>

      {price > 0 && (
        <div className="rounded-lg border border-border bg-accent/50 p-3 text-center">
          <span className="text-xs text-muted-foreground">Margen: </span>
          {margin == null ? (
            <span className="text-sm font-bold text-muted-foreground">—</span>
          ) : (
            <span className={`text-sm font-bold ${margin >= 50 ? "text-emerald-400" : margin >= 30 ? "text-yellow-400" : "text-red-400"}`}>
              {margin}%
            </span>
          )}
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
                  {/* Decisión 7: opción explícita para desasignar la unidad base. */}
                  <SelectItem value={NO_BASE_UNIT}>Sin unidad</SelectItem>
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
              {/* Decisión 7: quitar la unidad sigue sujeto a D11/D-C — se avisa
                  antes de guardar, con el mismo molde que la ayuda del costo. */}
              {initialData?.baseUnitId && baseUnitId === NO_BASE_UNIT && (
                <p className="text-[11px] text-muted-foreground">
                  Sólo se puede quitar si el producto no tiene stock ni movimientos.
                </p>
              )}
            </div>
          )}
        </div>
      )}

      {/* ── Stock fields (only for tracked products) ──────────────────────────── */}
      {stockControlType !== "untracked" && (
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Stock inicial</Label>
            {/* step="any": sin él el input es step=1 y el navegador bloquea el
                submit con 0,55 kg (stepMismatch). El servidor valida >= 0. */}
            <NumericInput min={0} step="any" value={stock} onValueChange={setStock} className="bg-background border-border text-foreground" />
          </div>
          <div className="flex flex-col gap-2">
            <Label className="text-foreground">Stock mínimo</Label>
            {/* Stock mínimo decimal (numeric(15,4), 0,5 kg): mismo motivo. */}
            <NumericInput min={0} step="any" value={minStock} onValueChange={setMinStock} className="bg-background border-border text-foreground" />
          </div>
        </div>
      )}

      <Button type="submit" className="w-full">
        {initialData ? "Actualizar producto" : "Crear producto"}
      </Button>
    </form>
  )
}
