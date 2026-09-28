"use client"

/**
 * balanza-etiquetas-pos (D11) — pestaña "Balanza" de /configuracion.
 *
 * Interruptor global + editor de los 3 formatos (peso/unidad/varios, D3/D4)
 * con "Resultado" en vivo (D3/D11), probador contra la configuración EN
 * EDICIÓN (D11.3, decodifica aunque `enabled` esté apagado), guía con los
 * pasos literales del manual (D11.4) y exportación del catálogo (D12).
 *
 * Owner/admin editan (`CAN_CONFIGURE`, mismo criterio que el backend); el
 * resto de los miembros ve la configuración en sólo lectura y puede usar el
 * probador y exportar.
 */

import { useMemo, useState } from "react"
import { toast } from "sonner"
import { Download, FlaskConical, RotateCcw, Save, ScanBarcode } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card"
import { Input } from "@/components/ui/input"
import { NumericInput } from "@/components/ui/numeric-input"
import { Label } from "@/components/ui/label"
import { Switch } from "@/components/ui/switch"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import {
  Accordion, AccordionContent, AccordionItem, AccordionTrigger,
} from "@/components/ui/accordion"
import { useOrgRole } from "@/hooks/useOrgRole"
import { useProducts } from "@/hooks/data/use-products"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { useProductCategories } from "@/hooks/data/use-product-categories"
import { useScaleSettings, useUpdateScaleSettings } from "@/hooks/data/use-scale-settings"
import {
  FACTORY_SCALE_SETTINGS,
  layoutResultPattern,
  maxRepresentableAmount,
  scaleSettingsSchema,
  type ScaleField,
  type ScaleLayout,
  type ScaleSegment,
  type ScaleSettings as ScaleSettingsType,
} from "@/lib/scale-layout"

type LayoutKind = ScaleLayout["kind"]
import { decodeScaleBarcode, scaleDecodeErrorMessage, type ScaleDecodeResult } from "@/lib/scale-barcode"
import { resolveScaleScan } from "@/lib/scale-cart"
import { buildScaleCsv, type BuildScaleCsvResult } from "@/lib/scale-export"
import { downloadTextFile } from "@/lib/excel"
import { convertUnitPrice, isBaseUnit, isProductoPorUnidades, resolveUnit } from "@/lib/unit-utils"
import { formatMoney } from "@/lib/format"
import type { Product } from "@/lib/types"

// ─── Constantes de presentación ───────────────────────────────────────────────

const LAYOUT_LABELS: Record<LayoutKind, string> = {
  weighed: "Venta por peso",
  unit: "Venta por unidad",
  multi: "Varios",
}

const FIELD_LABELS: Record<ScaleField, string> = {
  fixed: "Número fijo",
  plu: "Código (PLU)",
  amount: "Importe",
  quantity: "Cantidad (peso en kg o unidades)",
  ignored: "Otro (se ignora: tara, sección, n.º de balanza)",
}

const FIELD_OPTIONS: ScaleField[] = ["fixed", "plu", "amount", "quantity", "ignored"]
const FIELD_LETTERS = ["A", "B", "C", "D"] as const

/** Mensajes en español para cada código estable de D4 (`ScaleLayoutErrorCode`). */
const ERROR_MESSAGES: Record<string, string> = {
  segments_count_invalid: "El formato tiene que tener entre 1 y 4 campos (A a D).",
  digits_sum_not_12: "Los campos tienen que sumar 12 dígitos (el 13.º es el dígito verificador).",
  field_a_not_fixed: "El campo A tiene que ser un Número fijo (la cabecera de la etiqueta).",
  header_length_invalid:
    "El Número fijo del campo A tiene que tener entre 1 y 3 dígitos, con un valor de esa misma longitud.",
  header_not_starting_with_2: "El Número fijo del campo A tiene que empezar con 2.",
  plu_missing: "Tiene que haber exactamente un campo Código (PLU) — Varios no lleva PLU.",
  plu_digits_out_of_range: "El campo Código (PLU) admite de 1 a 6 dígitos.",
  value_field_count_invalid: "Tiene que haber exactamente un campo de Importe o Cantidad.",
  decimals_out_of_range: "Los decimales van de 0 a 3.",
  unit_quantity_decimals_invalid: "En la venta por unidad, la Cantidad no lleva decimales.",
  header_prefix_conflict:
    "La cabecera de un formato habilitado se pisa con la de otro (una es prefijo de la otra).",
}

function errorMessage(code: string): string {
  return ERROR_MESSAGES[code] ?? code
}

// ─── Segmentos: siempre 4 slots (A–D) en la UI ─────────────────────────────────

/** Rellena hasta 4 campos con "Otro" de 0 dígitos (D4: un campo con 0 dígitos se ignora). */
function padSegments(segments: ScaleSegment[]): ScaleSegment[] {
  const padded = [...segments]
  while (padded.length < 4) padded.push({ field: "ignored", digits: 0 })
  return padded.slice(0, 4)
}

function padLayout(layout: ScaleLayout): ScaleLayout {
  return { ...layout, segments: padSegments(layout.segments) }
}

function padSettings(settings: ScaleSettingsType): ScaleSettingsType {
  return {
    enabled: settings.enabled,
    layouts: settings.layouts.map(padLayout) as ScaleSettingsType["layouts"],
  }
}

function defaultDecimalsFor(kind: LayoutKind, field: ScaleField): number {
  if (field === "amount") return 2
  return kind === "weighed" ? 3 : 0
}

// ─── Errores D4 (zod) → mensajes por layout / generales ────────────────────────

function layoutIssues(settings: ScaleSettingsType, index: number): string[] {
  const parsed = scaleSettingsSchema.safeParse(settings)
  if (parsed.success) return []
  return parsed.error.issues
    .filter((i) => i.path[0] === "layouts" && i.path.length === 2 && i.path[1] === index)
    .map((i) => errorMessage(i.message))
}

function generalIssues(settings: ScaleSettingsType): string[] {
  const parsed = scaleSettingsSchema.safeParse(settings)
  if (parsed.success) return []
  return parsed.error.issues
    .filter((i) => i.path.length === 1 && i.path[0] === "layouts")
    .map((i) => errorMessage(i.message))
}

// ─── Desborde: producto con PLU cuyo precio de referencia supera el máximo ─────

function findOverflowingProduct(
  layout: ScaleLayout,
  products: Product[],
  units: ReturnType<typeof useUnitsOfMeasure>["units"],
): { product: Product; max: number } | null {
  if (layout.kind === "multi") return null
  const max = maxRepresentableAmount(layout)
  if (max == null) return null
  const unitsById = new Map(units.map((u) => [u.id, u]))
  const kgUnit = units.find((u) => u.type === "weight" && isBaseUnit(u))

  for (const p of products) {
    if (p.scalePlu == null) continue
    const baseUnit = resolveUnit(p.baseUnitId, unitsById)
    const isWeighed = baseUnit?.type === "weight"
    const isUnitSale = isProductoPorUnidades(baseUnit)
    if (layout.kind === "weighed" && !isWeighed) continue
    if (layout.kind === "unit" && !isUnitSale) continue
    const referencePrice =
      layout.kind === "weighed" && kgUnit && baseUnit
        ? convertUnitPrice(p.price, baseUnit, kgUnit, baseUnit)
        : p.price
    if (referencePrice > max) return { product: p, max }
  }
  return null
}

// ─── Probador ───────────────────────────────────────────────────────────────

function notScaleMessage(reason: Extract<ScaleDecodeResult, { status: "not_scale" }>["reason"]): string {
  switch (reason) {
    case "disabled":
      return "La lectura de etiquetas está deshabilitada."
    case "not_ean13":
      return "El código no tiene 13 dígitos: no es un EAN-13."
    case "no_layout_match":
      return "Ninguna cabecera configurada coincide con este código."
  }
}

// ─── Componente ───────────────────────────────────────────────────────────────

export function ScaleSettings() {
  const { role } = useOrgRole()
  const canConfigure = role === "owner" || role === "admin"

  const { settings, isLoading } = useScaleSettings()
  const { mutateAsync: saveSettings, isPending } = useUpdateScaleSettings()
  const { products } = useProducts()
  const { units } = useUnitsOfMeasure()
  const { productCategories } = useProductCategories(true)

  const [editing, setEditing] = useState<ScaleSettingsType>(() => padSettings(settings))
  const [saveError, setSaveError] = useState<string | null>(null)
  const [testerCode, setTesterCode] = useState("")
  const [testerResult, setTesterResult] = useState<ScaleDecodeResult | null>(null)
  const [exportSummary, setExportSummary] = useState<BuildScaleCsvResult | null>(null)

  const isValid = useMemo(() => scaleSettingsSchema.safeParse(editing).success, [editing])
  const overallErrors = useMemo(() => generalIssues(editing), [editing])

  function updateLayout(index: number, updater: (layout: ScaleLayout) => ScaleLayout) {
    setEditing((prev) => {
      const layouts = [...prev.layouts] as ScaleSettingsType["layouts"]
      layouts[index] = updater(layouts[index]) as ScaleLayout
      return { ...prev, layouts }
    })
  }

  function updateSegment(layoutIndex: number, segIndex: number, patch: Partial<ScaleSegment>) {
    updateLayout(layoutIndex, (layout) => {
      const segments = [...layout.segments]
      segments[segIndex] = { ...segments[segIndex], ...patch }
      return { ...layout, segments }
    })
  }

  function handleFieldChange(layoutIndex: number, segIndex: number, layout: ScaleLayout, field: ScaleField) {
    const current = layout.segments[segIndex]
    const patch: Partial<ScaleSegment> = { field }
    if (field === "amount" || field === "quantity") {
      patch.decimals = current.decimals ?? defaultDecimalsFor(layout.kind, field)
    } else {
      patch.decimals = undefined
    }
    if (field !== "fixed") patch.value = undefined
    updateSegment(layoutIndex, segIndex, patch)
  }

  function handleRestoreFactory() {
    setEditing(padSettings(FACTORY_SCALE_SETTINGS))
    setSaveError(null)
  }

  async function handleSave() {
    setSaveError(null)
    try {
      await saveSettings(editing)
      toast.success("Configuración de balanza guardada")
    } catch (error: unknown) {
      const msg = error instanceof Error && error.message ? error.message : "No se pudo guardar la configuración"
      setSaveError(msg)
      toast.error(msg)
    }
  }

  // ── Probador (D11.3): SIEMPRE con enabled=true, sobre la config EN EDICIÓN ──
  function handleTest(e: React.FormEvent) {
    e.preventDefault()
    const code = testerCode.trim()
    if (!code) return
    setTesterResult(decodeScaleBarcode(code, { ...editing, enabled: true }))
  }

  const testerScan = useMemo(() => {
    if (!testerResult || testerResult.status !== "ok") return null
    const unitsById = new Map(units.map((u) => [u.id, u]))
    return resolveScaleScan(testerResult, { products, units, unitsById })
  }, [testerResult, products, units])

  function handleExport() {
    const categoriesById = new Map(productCategories.map((c) => [c.id, c]))
    const result = buildScaleCsv(products, categoriesById, units, editing)
    const today = new Date().toISOString().slice(0, 10)
    downloadTextFile(result.csv, `balanza-aliadata-${today}.csv`, "text/plain;charset=us-ascii;")
    setExportSummary(result)
  }

  return (
    <div className="flex flex-col gap-6">
      {/* ── 1. Interruptor global ────────────────────────────────────────────── */}
      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-sm text-card-foreground">
            <ScanBarcode className="h-4 w-4" />
            Balanza etiquetadora
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <div className="flex items-center justify-between gap-4 rounded-lg border border-border bg-muted/20 px-4 py-3">
            <div className="flex flex-col gap-0.5">
              <Label htmlFor="scale-enabled-toggle" className="text-foreground">
                Leer etiquetas de balanza en el POS y en ventas
              </Label>
              <p className="text-xs text-muted-foreground">
                Con el interruptor apagado, el probador sigue funcionando para configurar y probar antes de activar.
              </p>
            </div>
            <Switch
              id="scale-enabled-toggle"
              checked={editing.enabled}
              disabled={!canConfigure || isLoading}
              onCheckedChange={(checked) => setEditing((prev) => ({ ...prev, enabled: checked }))}
            />
          </div>

          {overallErrors.map((msg, i) => (
            <p key={i} className="text-xs text-destructive">{msg}</p>
          ))}
          {saveError && <p className="text-xs text-destructive">{saveError}</p>}

          <div className="flex items-center gap-2">
            <Button type="button" onClick={handleSave} disabled={!isValid || !canConfigure || isPending}>
              <Save className="h-3.5 w-3.5 mr-1.5" />
              {isPending ? "Guardando…" : "Guardar"}
            </Button>
            <Button type="button" variant="outline" onClick={handleRestoreFactory} disabled={!canConfigure}>
              <RotateCcw className="h-3.5 w-3.5 mr-1.5" />
              Restaurar valores de fábrica
            </Button>
          </div>
        </CardContent>
      </Card>

      {/* ── 2. Formatos (D3/D4) ──────────────────────────────────────────────── */}
      <div className="flex flex-col gap-4">
        {editing.layouts.map((layout, index) => (
          <LayoutEditor
            key={layout.kind}
            layout={layout}
            index={index}
            disabled={!canConfigure}
            errors={layoutIssues(editing, index)}
            overflow={findOverflowingProduct(layout, products, units)}
            onToggleEnabled={(enabled) => updateLayout(index, (l) => ({ ...l, enabled }))}
            onSegmentChange={(segIndex, patch) => updateSegment(index, segIndex, patch)}
            onFieldChange={(segIndex, field) => handleFieldChange(index, segIndex, layout, field)}
          />
        ))}
      </div>

      {/* ── 3. Probador (D11.3) ──────────────────────────────────────────────── */}
      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="flex items-center gap-2 text-sm text-card-foreground">
            <FlaskConical className="h-4 w-4" />
            Probador
          </CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-3">
          <p className="text-xs text-muted-foreground">
            Prueba contra la configuración de ARRIBA, sin guardar — confirmá una etiqueta real antes de guardar y
            activar la lectura. Funciona aunque el interruptor esté apagado.
          </p>
          <form onSubmit={handleTest} className="flex flex-col gap-2 sm:flex-row sm:items-end">
            <div className="flex flex-col gap-2 flex-1">
              <Label htmlFor="scale-tester-input" className="text-foreground">
                Código a probar
              </Label>
              <Input
                id="scale-tester-input"
                value={testerCode}
                onChange={(e) => setTesterCode(e.target.value)}
                placeholder="Escaneá o tipeá el código de la etiqueta"
                className="bg-background border-border text-foreground"
              />
            </div>
            <Button type="submit" variant="outline">Probar</Button>
          </form>

          <div role="status" aria-live="polite" className="rounded-lg border border-border bg-muted/20 px-4 py-3 text-sm">
            <TesterOutput result={testerResult} scan={testerScan} editingEnabled={editing.enabled} />
          </div>
        </CardContent>
      </Card>

      {/* ── 4. Guía + exportación (D11.4/D12) ───────────────────────────────── */}
      <Card className="border-border bg-card">
        <CardHeader className="pb-3">
          <CardTitle className="text-sm text-card-foreground">Guía para configurar la balanza</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col gap-4">
          <ScaleGuideAccordion />

          <div className="flex flex-col gap-2 rounded-lg border border-border bg-muted/20 px-4 py-3">
            <p className="text-sm font-medium text-foreground">Exportar catálogo para la balanza</p>
            <p className="text-xs text-muted-foreground">
              Genera el archivo del Formato 1 de Systel Suite Neo con los productos que tienen Código de balanza
              asignado. No consume la cuota de exportaciones del plan.
            </p>
            <Button type="button" variant="outline" className="w-fit" onClick={handleExport}>
              <Download className="h-3.5 w-3.5 mr-1.5" />
              Exportar catálogo para la balanza
            </Button>
            {exportSummary && (
              <div className="text-xs text-muted-foreground flex flex-col gap-1 mt-1">
                <p>{exportSummary.included} exportado{exportSummary.included === 1 ? "" : "s"}.</p>
                {exportSummary.skipped.length > 0 && (
                  <p>
                    {exportSummary.skipped.length} omitido{exportSummary.skipped.length === 1 ? "" : "s"}:{" "}
                    {exportSummary.skipped.map((s) => `${s.productName} (${s.reason})`).join(", ")}
                  </p>
                )}
                {exportSummary.warnings.length > 0 && (
                  <p>
                    {exportSummary.warnings.length} aviso{exportSummary.warnings.length === 1 ? "" : "s"}:{" "}
                    {exportSummary.warnings.map((w) => `${w.productName} (${w.reason})`).join(", ")}
                  </p>
                )}
              </div>
            )}
          </div>
        </CardContent>
      </Card>
    </div>
  )
}

// ─── Sub-componentes ──────────────────────────────────────────────────────────

function LayoutEditor({
  layout,
  index,
  disabled,
  errors,
  overflow,
  onToggleEnabled,
  onSegmentChange,
  onFieldChange,
}: {
  layout: ScaleLayout
  index: number
  disabled: boolean
  errors: string[]
  overflow: { product: Product; max: number } | null
  onToggleEnabled: (enabled: boolean) => void
  onSegmentChange: (segIndex: number, patch: Partial<ScaleSegment>) => void
  onFieldChange: (segIndex: number, field: ScaleField) => void
}) {
  const label = LAYOUT_LABELS[layout.kind]
  const pattern = layoutResultPattern(layout)
  const max = maxRepresentableAmount(layout)

  return (
    <Card className="border-border bg-card">
      <CardHeader className="pb-3">
        <div className="flex items-center justify-between gap-3">
          <CardTitle className="text-sm text-card-foreground">{label}</CardTitle>
          <div className="flex items-center gap-2">
            <Label htmlFor={`scale-layout-${layout.kind}-enabled`} className="text-xs text-muted-foreground">
              Habilitado
            </Label>
            <Switch
              id={`scale-layout-${layout.kind}-enabled`}
              aria-label={`Habilitar ${label}`}
              checked={layout.enabled}
              disabled={disabled}
              onCheckedChange={onToggleEnabled}
            />
          </div>
        </div>
      </CardHeader>
      <CardContent className="flex flex-col gap-3">
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          {layout.segments.map((segment, segIndex) => (
            <div key={segIndex} className="flex flex-col gap-1.5 rounded-md border border-border p-2">
              <p className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">
                Campo {FIELD_LETTERS[segIndex]}
              </p>
              <Select
                value={segment.field}
                disabled={disabled}
                onValueChange={(v) => onFieldChange(segIndex, v as ScaleField)}
              >
                <SelectTrigger
                  aria-label={`Campo ${FIELD_LETTERS[segIndex]} — ${label}`}
                  className="bg-background border-border text-foreground text-xs"
                >
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-popover border-border">
                  {FIELD_OPTIONS.map((f) => (
                    <SelectItem key={f} value={f}>{FIELD_LABELS[f]}</SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <div className="flex items-center gap-2">
                <Label className="text-[11px] text-muted-foreground shrink-0">Dígitos</Label>
                <NumericInput
                  aria-label={`Dígitos campo ${FIELD_LETTERS[segIndex]} — ${label}`}
                  min={0}
                  max={12}
                  step={1}
                  value={segment.digits}
                  disabled={disabled}
                  onValueChange={(v) => onSegmentChange(segIndex, { digits: Math.trunc(v) })}
                  className="bg-background border-border text-foreground text-xs h-8"
                />
              </div>
              {segment.field === "fixed" && (
                <Input
                  aria-label={`Valor fijo campo ${FIELD_LETTERS[segIndex]} — ${label}`}
                  value={segment.value ?? ""}
                  disabled={disabled}
                  placeholder="Ej: 20"
                  onChange={(e) => onSegmentChange(segIndex, { value: e.target.value })}
                  className="bg-background border-border text-foreground text-xs h-8"
                />
              )}
              {(segment.field === "amount" || segment.field === "quantity") && (
                <div className="flex items-center gap-2">
                  <Label className="text-[11px] text-muted-foreground shrink-0">Decimales</Label>
                  <NumericInput
                    aria-label={`Decimales campo ${FIELD_LETTERS[segIndex]} — ${label}`}
                    min={0}
                    max={3}
                    step={1}
                    value={segment.decimals ?? defaultDecimalsFor(layout.kind, segment.field)}
                    disabled={disabled}
                    onValueChange={(v) => onSegmentChange(segIndex, { decimals: Math.trunc(v) })}
                    className="bg-background border-border text-foreground text-xs h-8"
                  />
                </div>
              )}
            </div>
          ))}
        </div>

        <div className="flex items-center gap-2 rounded-md bg-muted/30 px-3 py-2">
          <span className="text-[11px] font-semibold uppercase tracking-wide text-muted-foreground">Resultado</span>
          <span className="font-mono text-sm text-foreground">{pattern}</span>
        </div>

        {max != null && (
          <p className="text-xs text-muted-foreground">
            Importe máximo representable: {formatMoney(max)}{layout.kind === "weighed" ? " por kg" : ""}.
          </p>
        )}
        {overflow && (
          <p className="text-xs text-yellow-500">
            «{overflow.product.name}» supera el importe máximo representable ({formatMoney(overflow.max)}
            {layout.kind === "weighed" ? " por kg" : ""}) — una etiqueta de este producto podría no entrar en el
            código de barras.
          </p>
        )}

        {errors.map((msg, i) => (
          <p key={i} className="text-xs text-destructive">{msg}</p>
        ))}
      </CardContent>
    </Card>
  )
}

function TesterOutput({
  result,
  scan,
  editingEnabled,
}: {
  result: ScaleDecodeResult | null
  scan: ReturnType<typeof resolveScaleScan> | null
  editingEnabled: boolean
}) {
  if (!result) {
    return <p className="text-muted-foreground">Probá un código para ver el resultado acá.</p>
  }

  const disabledNotice = !editingEnabled && (
    <p className="text-[11px] text-muted-foreground mt-1">
      La lectura está deshabilitada: el POS todavía no lee etiquetas.
    </p>
  )

  if (result.status === "not_scale") {
    return (
      <div>
        <p className="text-foreground">{notScaleMessage(result.reason)}</p>
        {disabledNotice}
      </div>
    )
  }
  if (result.status === "invalid" || result.status === "unsupported") {
    return (
      <div>
        <p className="text-destructive">{scaleDecodeErrorMessage(result)}</p>
        {disabledNotice}
      </div>
    )
  }

  // status === "ok"
  const valueLabel = result.value.kind === "amount" ? "Importe" : result.value.kind === "weight" ? "Peso" : "Cantidad"
  return (
    <div className="flex flex-col gap-1">
      <p className="text-foreground">
        Formato {result.layout === "weighed" ? "de venta por peso" : "de venta por unidad"} — PLU{" "}
        <span className="font-semibold">{result.plu}</span> — {valueLabel}:{" "}
        <span className="font-semibold">
          {result.value.kind === "amount" ? formatMoney(result.value.amount) : result.value.amount}
        </span>
      </p>
      {scan?.ok && (
        <p className="text-foreground">
          Producto: <span className="font-semibold">{scan.line.productName}</span> — {scan.line.quantity}
          {scan.line.unitSymbol ?? ""} × {formatMoney(scan.line.unitPrice)} — Subtotal:{" "}
          <span className="font-semibold">{formatMoney(scan.line.subtotal)}</span>
        </p>
      )}
      {scan && !scan.ok && <p className="text-destructive">{scan.message}</p>}
      {disabledNotice}
    </div>
  )
}

const GUIDE_ITEM_VALUES = [
  "formato", "decimales", "plus", "papel", "imprime", "genericos", "terceros", "lector", "archivo",
]

function ScaleGuideAccordion() {
  return (
    <Accordion type="multiple" defaultValue={GUIDE_ITEM_VALUES} className="w-full">
      <AccordionItem value="formato">
        <AccordionTrigger className="text-sm">Formato del código de barras (págs. 134-135)</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            En la balanza: Menú → usuario y contraseña → Aceptar → <strong>Configuración</strong> →{" "}
            <strong>Códigos de Barra</strong> → elegí el <strong>Tipo</strong> (Pesable / Unitario / Varios) →
            completá los <strong>Campos A–D</strong> (tipo en el desplegable + cantidad de dígitos) → compará la
            línea <strong>Resultado</strong> con la de acá → Guardar.
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="decimales">
        <AccordionTrigger className="text-sm">Decimales del importe (pág. 98)</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            Menú → <strong>Altas y bajas</strong> → <strong>Monedas</strong> → Buscar → <strong>Precisión precios</strong>{" "}
            → Guardar. Es una <strong>hipótesis a confirmar con el probador</strong> — el manual no dice que esto
            fije los decimales del código de barras. Alternativa verificada: redistribuir los dígitos entre el
            Código y el Importe (pág. 135).
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="plus">
        <AccordionTrigger className="text-sm">PLUs (págs. 71-72)</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            Menú → <strong>Altas y bajas</strong> → <strong>PLU&apos;s</strong> → <strong>Nuevo</strong> →{" "}
            <strong>Código</strong> (el mismo número que "Código de balanza" acá), Código ERP, Modo de venta.
          </p>
          <p className="text-yellow-500">
            No uses <strong>"Reemplazar PLU por el número"</strong> (solapa "Cód. barras" del PLU, pág. 80): su
            efecto no está documentado y, si lo activás, la exportación deja de ser compatible.
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="papel">
        <AccordionTrigger className="text-sm">Rollo de etiquetas, una etiqueta por pesada</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            La acumulación de varios artículos en un comprobante ("Realice esta operación con el total de
            productos a vender") <strong>sólo funciona con papel continuo</strong> (pág. 35), y ese comprobante
            lleva el código de Varios, que Aliadata no carga. Trabajá con <strong>rollo de etiquetas</strong> (tipo
            de papel ETIQUETAS, pág. 17) en <strong>venta directa</strong> (etiqueta 2.1, pág. 33): cada pesada
            imprime su etiqueta. El modo pre-empaque (2.2) queda para mercadería pre-envasada.
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="imprime">
        <AccordionTrigger className="text-sm">Verificar que la etiqueta imprime el código de barras</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            El EAN-13 se imprime sólo si está configurado. Menú → Configuración → <strong>Asignar formato</strong>{" "}
            (pág. 132): verificá que los formatos pesable y unitario de venta directa lo impriman; en cada PLU,
            solapa <strong>"Cód. barras"</strong> (págs. 79-80), que la impresión esté activa.
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="genericos">
        <AccordionTrigger className="text-sm">Restringir la venta de genéricos (págs. 34, 113)</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            El PLU 0 es el artículo genérico de fábrica: su etiqueta no identifica el producto. Recomendación:
            restringir la venta de genéricos en Configuración → General → solapa Ventas.
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="terceros">
        <AccordionTrigger className="text-sm">Mercadería etiquetada por terceros</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            Si recibís productos pre-pesados con la etiqueta de la balanza de un proveedor (fiambre, queso),
            configurá en tu balanza una <strong>cabecera propia</strong> poco usada y copiala acá — evita que un
            PLU ajeno coincida con uno local.
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="lector">
        <AccordionTrigger className="text-sm">Lector de códigos</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            Habilitá en el lector la <strong>transmisión del dígito verificador EAN-13</strong> y el sufijo{" "}
            <strong>Enter</strong>. Probalo escaneando una etiqueta en el probador de arriba: tiene que recibir 13
            dígitos.
          </p>
        </AccordionContent>
      </AccordionItem>

      <AccordionItem value="archivo">
        <AccordionTrigger className="text-sm">Cómo llega el archivo a la balanza (págs. 113, 118-119)</AccordionTrigger>
        <AccordionContent className="text-xs text-muted-foreground flex flex-col gap-1.5">
          <p>
            Dos caminos, ninguno probado todavía con el equipo: (a) el <strong>Importador de Neo Basic Tools</strong>{" "}
            o Systel Suite Neo en una PC Windows — supuesto, la transmisión a la balanza no está documentada; con
            Suite Neo en red, la balanza deniega accesos que sólo puede operar el servidor (pág. 136). (b)
            Documentado de punta a punta: un <strong>servidor FTP/SFTP</strong> del propio comercio — Menú →
            Configuración → General → Importación → Formato de archivo: Systel, Ruta del archivo Artículos
            (el CSV exportado abajo).
          </p>
        </AccordionContent>
      </AccordionItem>
    </Accordion>
  )
}
