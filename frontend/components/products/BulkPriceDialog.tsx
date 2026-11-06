"use client"

import { useEffect, useId, useRef, useState } from "react"
import { AlertTriangle, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { NumericInput } from "@/components/ui/numeric-input"
import { RadioGroup, RadioGroupItem } from "@/components/ui/radio-group"
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table"
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import type {
  BulkPriceDirection,
  BulkPriceMode,
  ProductBulkPriceOutcome,
  ProductBulkPriceParams,
} from "@/hooks/data/use-products"
import { formatMoney } from "@/lib/format"
import { humanizeOperationError } from "@/lib/operation-errors"
import { toast } from "sonner"

interface BulkPriceDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** Ids seleccionados en el catálogo (padres y simples): un padre se expande a sus variantes en el servidor. */
  productIds: string[]
  /** Llama al servidor: `dryRun: true` es la vista previa, `false` la aplicación. */
  onAdjust: (params: ProductBulkPriceParams) => Promise<ProductBulkPriceOutcome>
  /** Después de aplicar TODO el lote (la pantalla limpia la selección). */
  onApplied?: () => void
}

type Preview =
  | { status: "loading"; key: string }
  | { status: "ready"; key: string; outcome: ProductBulkPriceOutcome }
  | { status: "error"; key: string; message: string }

function errorText(error: unknown): string {
  const raw = error instanceof Error ? (("code" in error && typeof error.code === "string" && error.code) || error.message) : String(error)
  return humanizeOperationError(raw, undefined, undefined, { documentLabel: "producto" }).message
}

const count = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

function ChoiceRadio({ id, value, label }: { id: string; value: string; label: string }) {
  return (
    <label htmlFor={id} className="flex cursor-pointer items-center gap-2 rounded-md border border-border bg-background px-3 py-2 text-sm text-foreground has-[[data-state=checked]]:border-primary has-[[data-state=checked]]:bg-primary/5">
      <RadioGroupItem id={id} value={value} />
      {label}
    </label>
  )
}

/**
 * productos-padre-variantes (D8/D10/D13) — «Modificar precios» en lote.
 *
 * Dirección (aumentar/bajar), modo (porcentaje/importe fijo) y valor, y SIEMPRE
 * la vista previa del servidor (dry-run) antes de poder confirmar: el cliente no
 * calcula nada. Cambiar cualquier valor invalida la vista previa. La aplicación
 * va en bloques de 500 (cada bloque atómico, el lote no): si uno falla, el
 * diálogo dice cuántos productos se aplicaron en vez de afirmar éxito o fracaso
 * total. Sólo dueño/administrador (la pantalla no pasa la acción al resto).
 */
export function BulkPriceDialog({ open, onOpenChange, productIds, onAdjust, onApplied }: BulkPriceDialogProps) {
  const baseId = useId()
  const [direction, setDirection] = useState<BulkPriceDirection>("increase")
  const [mode, setMode] = useState<BulkPriceMode>("percent")
  const [value, setValue] = useState(0)
  const [preview, setPreview] = useState<Preview | null>(null)
  const [applying, setApplying] = useState(false)
  const [applyMessage, setApplyMessage] = useState<string | null>(null)

  const inputsKey = `${direction}|${mode}|${value}`
  // Una vista previa sólo vale para los valores con los que se pidió.
  const current = preview && preview.key === inputsKey ? preview : null
  const outcome = current?.status === "ready" ? current.outcome : null
  const result = outcome?.result ?? null

  // En un teléfono el diálogo scrollea por dentro y el pie pegado tapa lo de abajo: al llegar la vista
  // previa se la trae a la vista (el margen deja lugar al pie).
  const previewRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (result) previewRef.current?.scrollIntoView?.({ block: "nearest", behavior: "smooth" })
  }, [result])

  const canPreview = value > 0 && !applying && current?.status !== "loading"
  const canApply = !!result && result.changed > 0 && !applying

  async function handlePreview() {
    if (!canPreview) return
    const key = inputsKey
    setApplyMessage(null)
    setPreview({ status: "loading", key })
    try {
      const out = await onAdjust({ productIds, mode, direction, value, dryRun: true })
      setPreview({ status: "ready", key, outcome: out })
    } catch (error: unknown) {
      setPreview({ status: "error", key, message: errorText(error) })
    }
  }

  async function handleApply() {
    if (!canApply) return
    setApplying(true)
    setApplyMessage(null)
    try {
      const out = await onAdjust({ productIds, mode, direction, value, dryRun: false })
      if (out.failure) {
        // Falla parcial: lo aplicado queda aplicado; se dice cuánto y por qué se cortó.
        setApplyMessage(
          `Se aplicó a ${out.appliedIds} de ${out.totalIds} productos (${count(out.result.changed, "precio cambiado", "precios cambiados")}). ` +
          `El resto no se tocó: ${errorText(out.failure.error)}`,
        )
        setPreview(null)
        return
      }
      if (out.result.changed === 0) toast.info("Ningún precio cambió con estos valores.")
      else toast.success(`Se actualizaron ${count(out.result.changed, "precio", "precios")}.`)
      onApplied?.()
      onOpenChange(false)
    } catch (error: unknown) {
      setApplyMessage(errorText(error))
      setPreview(null)
    } finally {
      setApplying(false)
    }
  }

  function reset(next: boolean) {
    if (applying) return
    if (!next) {
      setDirection("increase")
      setMode("percent")
      setValue(0)
      setPreview(null)
      setApplyMessage(null)
    }
    onOpenChange(next)
  }

  return (
    <Dialog open={open} onOpenChange={reset}>
      {/* `[&>*]:min-w-0`: los hijos del grid del diálogo no pueden ensancharlo (la tabla de la vista previa, los textos largos). */}
      <DialogContent className="bg-card border-border [&>*]:min-w-0">
        <DialogHeader>
          <DialogTitle className="text-card-foreground">Modificar precios</DialogTitle>
          <DialogDescription>
            {`Cambia el precio de ${count(productIds.length, "producto seleccionado", "productos seleccionados")}. Un producto con variantes cambia los precios de sus variantes. El costo no se toca.`}
          </DialogDescription>
        </DialogHeader>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-sm font-medium text-foreground">Qué hacer</legend>
            <RadioGroup aria-label="Qué hacer" value={direction} onValueChange={(v) => setDirection(v as BulkPriceDirection)}>
              <ChoiceRadio id={`${baseId}-inc`} value="increase" label="Aumentar" />
              <ChoiceRadio id={`${baseId}-dec`} value="decrease" label="Bajar" />
            </RadioGroup>
          </fieldset>
          <fieldset className="flex flex-col gap-2">
            <legend className="mb-1 text-sm font-medium text-foreground">Cómo</legend>
            <RadioGroup aria-label="Cómo" value={mode} onValueChange={(v) => setMode(v as BulkPriceMode)}>
              <ChoiceRadio id={`${baseId}-pct`} value="percent" label="Porcentaje (%)" />
              <ChoiceRadio id={`${baseId}-amt`} value="amount" label="Importe fijo ($)" />
            </RadioGroup>
          </fieldset>
        </div>

        <div className="flex flex-col gap-2">
          <Label htmlFor={`${baseId}-value`} className="text-foreground">
            {mode === "percent" ? "Valor (%)" : "Valor ($)"}
          </Label>
          <NumericInput
            id={`${baseId}-value`}
            min={0}
            step="any"
            value={value}
            onValueChange={setValue}
            className="bg-background border-border text-foreground"
          />
          <p className="text-[11px] text-muted-foreground">
            El precio nuevo se redondea a pesos enteros. Por porcentaje: una baja de hasta el 90 % o un aumento de hasta el 1.000 %.
          </p>
        </div>

        {current?.status === "loading" && (
          <p role="status" className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
            Calculando la vista previa…
          </p>
        )}

        {current?.status === "error" && (
          <div role="alert" className="flex items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <span>{current.message}</span>
          </div>
        )}

        {result && (
          <div ref={previewRef} className="flex scroll-mb-56 flex-col gap-3 rounded-lg border border-border bg-accent/40 p-3 text-sm" data-testid="bulk-price-preview">
            <ul className="flex flex-col gap-1 text-foreground">
              {result.changed > 0 ? (
                <li className="font-medium">{count(result.changed, "producto cambia", "productos cambian")}</li>
              ) : (
                <li className="font-medium">Ningún precio cambia con estos valores.</li>
              )}
              {result.unchanged > 0 && <li>{count(result.unchanged, "queda igual", "quedan igual")}</li>}
              {result.skippedParents > 0 && (
                <li>
                  {count(result.skippedParents, "producto con variantes omitido", "productos con variantes omitidos")}
                  <span className="text-muted-foreground"> (no tienen precio propio; cambian sus variantes)</span>
                </li>
              )}
              {result.clamped > 0 && <li>{`${result.clamped} ${result.clamped === 1 ? "acotado" : "acotados"} a $0 (no baja de cero)`}</li>}
            </ul>

            {result.sample.length > 0 && (
              <div className="overflow-x-auto">
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>Producto</TableHead>
                      <TableHead className="text-right">Antes</TableHead>
                      <TableHead className="text-right">Después</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {result.sample.map((row) => (
                      <TableRow key={row.id}>
                        <TableCell className="max-w-[10rem] truncate text-foreground">{row.name}</TableCell>
                        <TableCell className="text-right tabular-nums text-muted-foreground">{formatMoney(row.priceBefore)}</TableCell>
                        <TableCell className="text-right tabular-nums font-medium text-foreground">{formatMoney(row.priceAfter)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
                {result.changed > result.sample.length && (
                  <p className="mt-1 text-[11px] text-muted-foreground">{`Se muestran ${result.sample.length} ejemplos.`}</p>
                )}
              </div>
            )}

            <p className="text-xs text-muted-foreground">
              Deshacer con el porcentaje inverso no es exacto por el redondeo a pesos enteros: revisá la vista previa antes de aplicar.
            </p>
          </div>
        )}

        {applyMessage && (
          <div role="alert" className="flex items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <span>{applyMessage}</span>
          </div>
        )}

        {/* Pie pegado al borde inferior: en un teléfono el diálogo scrollea por dentro y el CTA tiene que quedar a la vista. */}
        <DialogFooter className="sticky bottom-0 -mx-6 -mb-6 gap-2 border-t border-border bg-card px-6 pb-6 pt-3 sm:gap-0">
          <Button type="button" variant="outline" onClick={() => reset(false)} disabled={applying}>
            {applyMessage ? "Cerrar" : "Cancelar"}
          </Button>
          <Button type="button" variant="secondary" onClick={() => void handlePreview()} disabled={!canPreview}>
            Ver vista previa
          </Button>
          <Button type="button" onClick={() => void handleApply()} disabled={!canApply}>
            {applying ? "Aplicando…" : "Aplicar cambio de precios"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
