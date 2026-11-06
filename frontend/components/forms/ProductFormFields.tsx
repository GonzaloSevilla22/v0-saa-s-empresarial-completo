"use client"

/**
 * productos-padre-variantes (D12) — bloques de campos COMPARTIDOS por los tres
 * formularios de producto (`ParentProductForm`, `SimpleProductForm`,
 * `VariantProductForm`). Se extrajeron tal cual del `product-form.tsx` único
 * (mismos ids, mismas ayudas) para que cada formulario pida sólo lo que su tipo
 * usa sin repetir markup ni reglas.
 */

import { useState, useMemo, useCallback } from "react"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { useBarcodeScanner } from "@/hooks/use-barcode-scanner"
import { useScaleSettings } from "@/hooks/data/use-scale-settings"
import { useOrgRole } from "@/hooks/useOrgRole"
import { generateEAN13 } from "@/lib/barcode-utils"
import { decodeScaleBarcode } from "@/lib/scale-barcode"
import { isProductoPorUnidades } from "@/lib/unit-utils"
import { formatStock } from "@/lib/format-unit"
import { CAN_CONFIGURE, hasCapability } from "@/lib/rbac-capabilities"
import { nextPriceOnCostChange, SUGGESTED_MARKUP_FACTOR } from "@/lib/product-pricing"
import { cn } from "@/lib/utils"
import { NO_BASE_UNIT, UnitSelect } from "@/components/forms/UnitSelect"
import { toast } from "sonner"
import { Barcode, ScanLine, SlidersHorizontal, X } from "lucide-react"



// `NO_BASE_UNIT` vive con el selector; se re-exporta para los formularios.
export { NO_BASE_UNIT }

// ── Nombre ───────────────────────────────────────────────────────────────────

export function ProductNameField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor="product-name" className="text-foreground">Nombre</Label>
      <Input
        id="product-name"
        selectOnFocus
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder="Ej: Remera AFA - Talle S"
        className="bg-background border-border text-foreground"
      />
    </div>
  )
}

// ── Código de barras (escáner + EAN-13) ──────────────────────────────────────

export function BarcodeField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  const [isScanning, setIsScanning] = useState(false)

  // balanza-etiquetas-pos (D6): la lectura de configuración es la de la
  // cuenta TAL CUAL (sin forzar `enabled`, a diferencia del probador de la
  // pestaña Balanza — acá es sólo un aviso, no una confirmación previa).
  const { settings: scaleSettings } = useScaleSettings()
  const scaleBarcodeWarning = useMemo(() => {
    if (!value.trim()) return null
    const decoded = decodeScaleBarcode(value.trim(), scaleSettings)
    if (decoded.status !== "ok") return null
    return "Esto es una etiqueta de balanza; asigná el PLU en \"Código de balanza\" en vez de usar este código de barras."
  }, [value, scaleSettings])

  const handleScanComplete = useCallback((code: string) => {
    onChange(code)
    setIsScanning(false)
    toast.success(`Código escaneado: ${code}`)
  }, [onChange])

  useBarcodeScanner({ onScan: handleScanComplete, enabled: isScanning })

  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor="product-barcode" className="text-foreground">Código de Barras</Label>
      <div className="flex gap-2">
        <Input
          id="product-barcode"
          selectOnFocus
          value={value}
          onChange={(e) => onChange(e.target.value)}
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
        <Button type="button" variant="outline" size="icon" onClick={() => onChange(generateEAN13())} title="Generar EAN-13 válido">
          <Barcode className="h-4 w-4" />
        </Button>
      </div>
      {isScanning && (
        <p className="text-[11px] text-primary animate-pulse">
          Apunte el lector al código de barras...
        </p>
      )}
      {/* balanza-etiquetas-pos (D6): aviso no bloqueante — este código es una
          etiqueta de balanza, no un código de barras común. */}
      {scaleBarcodeWarning && <p className="text-[11px] text-warning">{scaleBarcodeWarning}</p>}
    </div>
  )
}

// ── Código de balanza (PLU) ──────────────────────────────────────────────────

interface ScalePluFieldProps {
  value: number | null
  onChange: (v: number | null) => void
  error: string | null
  /** Unidad efectiva: decide qué formato de etiqueta (peso/unidad) mide el aviso de dígitos. */
  baseUnitId: string | undefined
}

/**
 * balanza-etiquetas-pos (D2/D12): aviso no bloqueante si el PLU tiene más
 * dígitos que el campo "Código" del formato de venta habilitado que le
 * corresponde (peso/unidad, según la unidad base) — no entraría en la etiqueta
 * que exporta el catálogo (D12). Nunca se muestra para un padre.
 */
export function ScalePluField({ value, onChange, error, baseUnitId }: ScalePluFieldProps) {
  const { units } = useUnitsOfMeasure()
  const { settings: scaleSettings } = useScaleSettings()

  const digitsWarning = useMemo(() => {
    if (value == null) return null
    const unit = units.find((u) => u.id === baseUnitId)
    const relevantKind = unit?.type === "weight" ? "weighed" : isProductoPorUnidades(unit) ? "unit" : null
    if (!relevantKind) return null
    const layout = scaleSettings.layouts.find((l) => l.kind === relevantKind && l.enabled)
    const pluSegment = layout?.segments.find((s) => s.field === "plu")
    if (!pluSegment) return null
    const maxPlu = 10 ** pluSegment.digits - 1
    if (value <= maxPlu) return null
    return `El PLU ${value} tiene más dígitos que el campo Código del formato configurado (máximo ${maxPlu}) — no entraría en la etiqueta.`
  }, [value, units, baseUnitId, scaleSettings])

  return (
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
        value={value}
        onValueChange={(v) => onChange(v == null ? null : Math.trunc(v))}
        className="bg-background border-border text-foreground"
      />
      <p className="text-[11px] text-muted-foreground">
        El código de PLU que la balanza imprime en la etiqueta (Configuración → Balanza).
      </p>
      {digitsWarning && <p className="text-[11px] text-warning">{digitsWarning}</p>}
      {error && <p className="text-[11px] text-destructive">{error}</p>}
    </div>
  )
}

// ── SKU ──────────────────────────────────────────────────────────────────────

export function SkuField({ value, onChange }: { value: string; onChange: (v: string) => void }) {
  return (
    <div className="flex flex-col gap-2">
      <Label htmlFor="product-sku" className="text-foreground">
        SKU <span className="text-muted-foreground font-normal">(opcional)</span>
      </Label>
      <Input
        id="product-sku"
        selectOnFocus
        value={value}
        onChange={(e) => onChange(e.target.value)}
        placeholder="Ej: REM-001"
        className="bg-background border-border text-foreground"
      />
    </div>
  )
}

// ── Costo + precio (con sugerencia ×1,5 y margen) ────────────────────────────

/**
 * Estado de costo y precio con la sugerencia de D11: escribir el costo completa
 * el precio con `costo × 1,5` SÓLO si el precio está vacío o es la última
 * sugerencia; un precio escrito a mano (o el que ya trae una edición) nunca se
 * pisa. La regla es la función pura `nextPriceOnCostChange`; esto sólo la conecta.
 *
 * productos-costo-nullable: `cost` es OPCIONAL — `null` = sin costo cargado,
 * nunca 0 por default. `costTouched` distingue "no lo toqué" de "lo dejé en el
 * mismo valor" para el tri-estado de la edición (D12).
 */
export function useCostPriceFields(initial: { cost: number | null; price: number }) {
  const [cost, setCost] = useState<number | null>(initial.cost)
  const [costTouched, setCostTouched] = useState(false)
  const [price, setPrice] = useState(initial.price)
  const [lastSuggested, setLastSuggested] = useState<number | null>(null)

  const onCostChange = useCallback((value: number | null) => {
    setCost(value)
    setCostTouched(true)
    const next = nextPriceOnCostChange({ cost: value, price, lastSuggested })
    setPrice(next.price)
    setLastSuggested(next.lastSuggested)
  }, [price, lastSuggested])

  const onPriceChange = useCallback((value: number) => {
    setPrice(value)
    // Lo escribió una persona: la sugerencia deja de aplicarse.
    setLastSuggested(null)
  }, [])

  // Sin costo, el margen es ausente — nunca 0 ni un valor derivado de un costo
  // inventado (capability product-cost).
  const margin = cost == null ? null : (price > 0 ? Math.round(((price - cost) / price) * 100) : 0)

  return { cost, costTouched, price, margin, onCostChange, onPriceChange }
}

export function CostPriceFields({ fields }: { fields: ReturnType<typeof useCostPriceFields> }) {
  const { cost, price, margin, onCostChange, onPriceChange } = fields
  return (
    <>
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
        <div className="flex flex-col gap-2">
          <Label htmlFor="product-cost" className="text-foreground">Costo</Label>
          <NumericInput
            id="product-cost"
            nullable
            min={0}
            step={0.01}
            value={cost}
            onValueChange={onCostChange}
            className="bg-background border-border text-foreground"
          />
          {/* productos-costo-nullable (D15): un campo opcional se declara como tal. */}
          <p className="text-[11px] text-muted-foreground">
            Dejalo vacío si todavía no sabés el costo.
          </p>
        </div>
        <div className="flex flex-col gap-2">
          <Label htmlFor="product-price" className="text-foreground">Precio</Label>
          <NumericInput
            id="product-price"
            min={0}
            step={0.01}
            value={price}
            onValueChange={onPriceChange}
            className="bg-background border-border text-foreground"
          />
          {/* productos-padre-variantes (D11): ayuda visible de la sugerencia. */}
          <p className="text-[11px] text-muted-foreground">
            {`Al cargar el costo se sugiere el precio: costo × ${String(SUGGESTED_MARKUP_FACTOR).replace(".", ",")}. Podés cambiarlo cuando quieras.`}
          </p>
        </div>
      </div>

      {price > 0 && (
        <div className="rounded-lg border border-border bg-accent/50 p-3 text-center">
          <span className="text-xs text-muted-foreground">Margen: </span>
          {margin == null ? (
            <span className="text-sm font-bold text-muted-foreground">—</span>
          ) : (
            <span className={cn("text-sm font-bold", margin >= 50 ? "text-success" : margin >= 30 ? "text-warning" : "text-destructive")}>
              {margin}%
            </span>
          )}
        </div>
      )}
    </>
  )
}

// ── Unidad de medida ─────────────────────────────────────────────────────────

interface ProductUnitFieldProps {
  label?: string
  value: string
  onChange: (v: string) => void
  /** Unidad que el producto ya tiene guardada (para el aviso de "Sin unidad" y el texto de sólo lectura). */
  savedUnitId?: string
  /**
   * El grupo tiene stock o movimientos: el selector libre se reemplaza por la
   * acción "Corregir unidad" (dueño/administrador) o por un texto de sólo
   * lectura (el resto). Sin esto, el selector de siempre.
   */
  hasHistory?: boolean
  /** Abre el diálogo "Corregir unidad" (lo monta el formulario FUERA del <form>). */
  onCorrectUnit?: () => void
}

export function ProductUnitField({ label = "Unidad de medida", value, onChange, savedUnitId, hasHistory, onCorrectUnit }: ProductUnitFieldProps) {
  const { units, unitsById } = useUnitsOfMeasure()
  const { roles, rolesResolved } = useOrgRole()
  const canConfigure = hasCapability(roles, CAN_CONFIGURE, rolesResolved)

  if (units.length === 0) return null

  if (hasHistory) {
    const saved = savedUnitId ? unitsById?.get(savedUnitId) ?? units.find((u) => u.id === savedUnitId) : undefined
    return (
      <div className="flex flex-col gap-2">
        <span className="text-sm font-medium text-foreground">{label}</span>
        <div className="flex flex-wrap items-center gap-2">
          <span data-testid="current-unit" className="text-sm font-semibold text-foreground">
            {saved ? `${saved.name} (${saved.symbol})` : "Sin unidad"}
          </span>
          {canConfigure && onCorrectUnit && (
            <Button type="button" variant="outline" size="sm" onClick={onCorrectUnit}>
              Corregir unidad
            </Button>
          )}
        </div>
        <p className="text-[11px] text-muted-foreground">
          {canConfigure
            ? "Ya tiene stock o movimientos, así que la unidad no se cambia desde acá. «Corregir unidad» cambia el rótulo de toda la familia sin convertir ninguna cantidad."
            : "Ya tiene stock o movimientos: la unidad la corrige un administrador o el dueño."}
        </p>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-2">
      <Label className="text-foreground">{label}</Label>
      <UnitSelect value={value} onChange={onChange} />
      {/* Decisión 7: quitar la unidad sigue sujeto a D11/D-C — se avisa antes de
          guardar, con el mismo molde que la ayuda del costo. */}
      {savedUnitId && value === NO_BASE_UNIT && (
        <p className="text-[11px] text-muted-foreground">
          Sólo se puede quitar si el producto no tiene stock ni movimientos.
        </p>
      )}
    </div>
  )
}

/** Unidad heredada, de sólo lectura (variante): se muestra la de su padre. */
export function InheritedUnitField({ unitId }: { unitId: string | undefined }) {
  const { units, unitsById } = useUnitsOfMeasure()
  const unit = unitId ? unitsById?.get(unitId) ?? units.find((u) => u.id === unitId) : undefined
  return (
    <div className="flex flex-col gap-2">
      <span className="text-sm font-medium text-foreground">Unidad de medida</span>
      <span data-testid="inherited-unit" className="text-sm font-semibold text-foreground">
        {unit ? `${unit.name} (${unit.symbol})` : "Sin unidad"}
      </span>
      <p className="text-[11px] text-muted-foreground">
        La unidad la define el producto padre: toda la familia usa la misma.
      </p>
    </div>
  )
}

/** Categoría heredada, de sólo lectura (variante). */
export function InheritedCategoryField({ name }: { name: string | undefined }) {
  return (
    <div className="flex flex-col gap-2">
      <span className="text-sm font-medium text-foreground">Categoría</span>
      <span data-testid="inherited-category" className="text-sm font-semibold text-foreground">{name || "—"}</span>
      <p className="text-[11px] text-muted-foreground">La categoría la define el producto padre.</p>
    </div>
  )
}

// ── Stock (stock-ledger-solo-rpc, D9) ────────────────────────────────────────

interface StockFieldsProps {
  /** Edición: «Stock actual» de sólo lectura + «Ajustar stock». Alta: «Stock inicial». */
  isEdit: boolean
  holdsStock: boolean
  canAdjust: boolean
  stock: number
  onStockChange: (v: number) => void
  minStock: number
  onMinStockChange: (v: number) => void
  liveStock: number
  unitSymbol?: string
  onAdjustStock: () => void
}

/**
 * Alta: «Stock inicial» sólo con CAN_STOCK y producto con stock propio; sin el
 * rol, una línea dice quién lo carga. Edición: «Stock actual» de sólo lectura +
 * «Ajustar stock» (modal con motivo). El stock mínimo NO es un ajuste y lo edita
 * cualquier rol.
 */
export function StockFields({
  isEdit, holdsStock, canAdjust, stock, onStockChange, minStock, onMinStockChange, liveStock, unitSymbol, onAdjustStock,
}: StockFieldsProps) {
  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
      {!isEdit && holdsStock && canAdjust && (
        <div className="flex flex-col gap-2">
          <Label htmlFor="product-stock-initial" className="text-foreground">Stock inicial</Label>
          {/* step="any": sin él el input es step=1 y el navegador bloquea el
              submit con 0,55 kg (stepMismatch). El servidor valida >= 0. */}
          <NumericInput id="product-stock-initial" min={0} step="any" value={stock} onValueChange={onStockChange} className="bg-background border-border text-foreground" />
          <p className="text-[11px] text-muted-foreground">
            Queda registrado en el historial como «Stock inicial».
          </p>
        </div>
      )}
      {!isEdit && holdsStock && !canAdjust && (
        <div className="flex flex-col gap-2">
          <span className="text-sm font-medium text-foreground">Stock inicial</span>
          <p className="text-[11px] text-muted-foreground">
            El stock inicial lo carga el depósito, un administrador o el dueño: creá el producto y pedile que lo ajuste desde Stock.
          </p>
        </div>
      )}
      {isEdit && holdsStock && (
        <div className="flex flex-col gap-2">
          <span className="text-sm font-medium text-foreground">Stock actual</span>
          <div className="flex items-center gap-2">
            <span data-testid="current-stock" className="text-sm font-semibold tabular-nums text-foreground">
              {formatStock(liveStock, unitSymbol)}
            </span>
            {canAdjust && (
              <Button type="button" variant="outline" size="sm" className="gap-1.5" onClick={onAdjustStock}>
                <SlidersHorizontal className="h-3.5 w-3.5" aria-hidden="true" />
                Ajustar stock
              </Button>
            )}
          </div>
          <p className="text-[11px] text-muted-foreground">
            {canAdjust
              ? "El stock se cambia con «Ajustar stock»: pide un motivo y queda en el historial."
              : "El stock lo ajusta el depósito, un administrador o el dueño."}
          </p>
        </div>
      )}
      <div className="flex flex-col gap-2">
        <Label htmlFor="product-min-stock" className="text-foreground">Stock mínimo</Label>
        {/* Stock mínimo decimal (numeric(15,4), 0,5 kg): mismo motivo. */}
        <NumericInput id="product-min-stock" min={0} step="any" value={minStock} onValueChange={onMinStockChange} className="bg-background border-border text-foreground" />
      </div>
    </div>
  )
}
