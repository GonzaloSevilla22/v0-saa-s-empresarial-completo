"use client"

import { useEffect, useRef, useState } from "react"
import { AlertTriangle, Loader2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { Label } from "@/components/ui/label"
import { Dialog, DialogContent, DialogDescription, DialogFooter, DialogHeader, DialogTitle } from "@/components/ui/dialog"
import { UnitSelect } from "@/components/forms/UnitSelect"
import { useRelabelProductUnit, type ProductUnitRelabelResult } from "@/hooks/data/use-products"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"
import { humanizeOperationError } from "@/lib/operation-errors"
import { toast } from "sonner"
import type { Product } from "@/lib/types"

interface RelabelUnitDialogProps {
  open: boolean
  onOpenChange: (open: boolean) => void
  /** El padre (o producto simple) cuya familia se corrige. */
  product: Product
  /**
   * Cantidad REAL con la que se arma el ejemplo («12 u pasarán a leerse 12 kg»):
   * el stock actual de la familia. Con 0 (sin existencias) el ejemplo usa 1.
   */
  exampleQuantity: number
  /** Después de aplicar la corrección, con la unidad que quedó (el formulario la adopta para no re-enviar la vieja). */
  onDone?: (unitId: string) => void
}

type Preview =
  | { status: "idle" }
  | { status: "loading" }
  | { status: "ready"; result: ProductUnitRelabelResult }
  | { status: "error"; message: string }

function errorText(error: unknown): string {
  const raw = error instanceof Error ? (("code" in error && typeof error.code === "string" && error.code) || error.message) : String(error)
  return humanizeOperationError(raw, undefined, undefined, { documentLabel: "producto" }).message
}

const qty = (n: number) => n.toLocaleString("es-AR", { maximumFractionDigits: 4 })
const plural = (n: number, one: string, many: string) => `${n} ${n === 1 ? one : many}`

/**
 * productos-padre-variantes (D5/D13) — «Corregir unidad».
 *
 * Cambia el RÓTULO de la unidad de toda la familia (el padre y sus variantes)
 * aunque haya historia: NINGUNA cantidad se convierte. Por eso antes de confirmar
 * se muestra la vista previa del SERVIDOR (dry-run, nunca un cálculo del cliente):
 * variantes, productos con stock, movimientos y un ejemplo con una cantidad real.
 * Una línea grabada en otra unidad (`conflictUnit`) se explica y deshabilita la
 * confirmación. La acción sólo se ofrece a dueño y administrador (el servidor
 * lo vuelve a exigir).
 */
export function RelabelUnitDialog({ open, onOpenChange, product, exampleQuantity, onDone }: RelabelUnitDialogProps) {
  const { relabel } = useRelabelProductUnit()
  const { unitsById, units } = useUnitsOfMeasure()
  const [unitId, setUnitId] = useState("")
  const [preview, setPreview] = useState<Preview>({ status: "idle" })
  const [applying, setApplying] = useState(false)
  const [applyError, setApplyError] = useState<string | null>(null)
  // Sólo vale la respuesta del último pedido (si se cambia de unidad mientras carga).
  const requestSeq = useRef(0)

  const unitOf = (id: string | null | undefined) =>
    id ? unitsById?.get(id) ?? units.find((u) => u.id === id) : undefined

  useEffect(() => {
    if (!open) {
      setUnitId("")
      setPreview({ status: "idle" })
      setApplyError(null)
    }
  }, [open])

  useEffect(() => {
    if (!open || !unitId) return
    const seq = ++requestSeq.current
    setPreview({ status: "loading" })
    setApplyError(null)
    relabel({ productId: product.id, baseUnitId: unitId, dryRun: true })
      .then((result) => { if (seq === requestSeq.current) setPreview({ status: "ready", result }) })
      .catch((error: unknown) => { if (seq === requestSeq.current) setPreview({ status: "error", message: errorText(error) }) })
    // `relabel` es estable por mutación; el pedido depende de la unidad elegida.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [open, unitId, product.id])

  const result = preview.status === "ready" ? preview.result : null

  // En un teléfono el diálogo scrollea por dentro y el pie pegado tapa lo de abajo: al llegar la vista
  // previa se la trae a la vista (el margen deja lugar al pie).
  const impactRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    if (result) impactRef.current?.scrollIntoView?.({ block: "nearest", behavior: "smooth" })
  }, [result])
  const conflictUnit = result?.conflictUnit ? unitOf(result.conflictUnit) : null
  const hasConflict = !!result?.conflictUnit
  const nothingToChange = !!result && !result.changed && !hasConflict
  const canConfirm = !!result && result.changed && !hasConflict && !applying

  const before = unitOf(result?.unitBefore ?? product.baseUnitId)
  const after = unitOf(result?.unitAfter ?? unitId)
  const exampleQty = exampleQuantity > 0 ? exampleQuantity : 1

  async function handleConfirm() {
    if (!canConfirm) return
    setApplying(true)
    setApplyError(null)
    try {
      await relabel({ productId: product.id, baseUnitId: unitId, dryRun: false })
      toast.success(`Unidad corregida: ahora «${product.name}» y sus variantes se miden en ${after?.name ?? "la unidad elegida"}.`)
      onDone?.(unitId)
      onOpenChange(false)
    } catch (error: unknown) {
      setApplyError(errorText(error))
    } finally {
      setApplying(false)
    }
  }

  return (
    <Dialog open={open} onOpenChange={(next) => { if (!applying) onOpenChange(next) }}>
      {/* `[&>*]:min-w-0`: los hijos del grid del diálogo no pueden ensancharlo (la tabla de la vista previa, los textos largos). */}
      <DialogContent className="bg-card border-border [&>*]:min-w-0">
        <DialogHeader>
          <DialogTitle className="text-card-foreground">Corregir unidad</DialogTitle>
          <DialogDescription>
            {`Cambia la unidad de «${product.name}» y de todas sus variantes. Sólo cambia el rótulo: no se convierte ninguna cantidad.`}
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-2">
          <Label className="text-foreground">Unidad nueva</Label>
          <UnitSelect value={unitId} onChange={setUnitId} allowNone={false} aria-label="Unidad nueva" />
        </div>

        {preview.status === "loading" && (
          <p role="status" className="flex items-center gap-2 text-sm text-muted-foreground">
            <Loader2 className="h-4 w-4 animate-spin" aria-hidden="true" />
            Calculando el impacto…
          </p>
        )}

        {preview.status === "error" && (
          <div role="alert" className="flex items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <span>{preview.message}</span>
          </div>
        )}

        {hasConflict && (
          <div ref={impactRef} role="alert" className="flex scroll-mb-56 items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <span>
              {`Hay ventas, compras u otros comprobantes de esta familia registrados en otra unidad: ${
                conflictUnit ? `${conflictUnit.name} (${conflictUnit.symbol})` : "una unidad distinta"
              }. Sólo se puede corregir hacia esa unidad; con ${after?.name ?? "la unidad elegida"} no es posible.`}
            </span>
          </div>
        )}

        {nothingToChange && (
          <p className="text-sm text-muted-foreground">La familia ya usa esa unidad: no hay nada que corregir.</p>
        )}

        {result && result.changed && !hasConflict && (
          <div ref={impactRef} className="flex scroll-mb-56 flex-col gap-3 rounded-lg border border-border bg-accent/40 p-3 text-sm">
            <p className="font-medium text-foreground">Esto es lo que va a cambiar de rótulo:</p>
            <ul className="flex list-disc flex-col gap-1 pl-5 text-foreground">
              <li>{plural(result.variants, "variante", "variantes")}</li>
              <li>{plural(result.productsWithStock, "producto con stock", "productos con stock")}</li>
              <li>{plural(result.movements, "movimiento", "movimientos")} del historial</li>
            </ul>
            {before && after && (
              <p className="text-foreground">
                {`${qty(exampleQty)} ${before.symbol} ${exampleQty === 1 ? "pasará" : "pasarán"} a leerse ${qty(exampleQty)} ${after.symbol}.`}
              </p>
            )}
            <p className="text-xs text-muted-foreground">
              No se convierte ninguna cantidad: si pasás de una unidad a otra distinta (por ejemplo de kg a g), las
              cantidades quedan igual y tenés que ajustarlas vos. Queda registrado y se puede volver atrás con otra corrección.
            </p>
          </div>
        )}

        {applyError && (
          <div role="alert" className="flex items-start gap-2 rounded-lg border border-destructive/30 bg-destructive/10 p-3 text-sm text-destructive">
            <AlertTriangle className="mt-0.5 h-4 w-4 shrink-0" aria-hidden="true" />
            <span>{applyError}</span>
          </div>
        )}

        {/* Pie pegado al borde inferior: en un teléfono el diálogo scrollea por dentro y el CTA tiene que quedar a la vista. */}
        <DialogFooter className="sticky bottom-0 -mx-6 -mb-6 gap-2 border-t border-border bg-card px-6 pb-6 pt-3 sm:gap-0">
          <Button type="button" variant="outline" onClick={() => onOpenChange(false)} disabled={applying}>
            Cancelar
          </Button>
          <Button type="button" onClick={() => void handleConfirm()} disabled={!canConfirm}>
            {applying ? "Corrigiendo…" : "Confirmar corrección"}
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  )
}
