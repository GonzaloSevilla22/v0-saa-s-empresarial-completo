"use client"

/**
 * StockImportAdjustmentDialog
 *
 * 3-step dialog for bulk stock adjustments via CSV upload.
 *
 * Step 1 — Upload
 *   Accept a .csv file (comma or semicolon delimited, UTF-8 with/without BOM).
 *   Show a downloadable template and the list of supported type values.
 *   stock-ledger-solo-rpc (tanda B): la columna «Motivo» es OBLIGATORIA (la base
 *   exige un motivo en las tres RPCs de ajuste) y las transferencias dejaron de
 *   ser un tipo de ajuste (OQ-1: «Transferir stock»). Un CSV sin la columna se
 *   rechaza como error de archivo; una fila con la celda vacía queda bloqueada.
 *
 * Step 2 — Preview & validation
 *   For each CSV row:
 *     - Resolve the product by name (exact → partial → not found).
 *     - Validate the type column (maps Spanish labels to DB types).
 *     - Validate the quantity (numeric, comma or dot decimals, > 0 for non-physical_count).
 *       Pure parsing lives in `lib/stock-import-parser.ts` (uses the canonical `parseAmount`).
 *     - Check for variant_only / untracked products (blocked).
 *   Show a table with per-row status badges (OK / warning / error).
 *   Block confirm if there are any blocking errors.
 *   The user can proceed even with warnings.
 *
 * Step 3 — Result
 *   Applies every valid row sequentially via rpc_stock_adjustment.
 *   Shows a summary: «N aplicados · M con error · K omitidas» (panel y toast, el
 *   mismo texto). stock-import-resultado-parcial: una fila bloqueada por el parser
 *   es OMITIDA (nunca llegó a la RPC) y se lista en «Filas omitidas» con su motivo;
 *   «con error» es sólo un rechazo REAL de la RPC (rol, stock insuficiente…), que
 *   se lista en «Detalle de errores» con su mensaje en castellano. Todo conteo
 *   concuerda en singular y plural (`countLabel`).
 *
 * Product resolution by name:
 *   1. Exact match (case-insensitive): OK
 *   2. One partial match:             OK + warning "se asignó a X"
 *   3. Multiple partial matches:      error — ambiguous
 *   4. No match:                      error — not found
 */

import { useState, useCallback, useMemo, useRef } from "react"
import { createClient } from "@/lib/supabase/client"
import { useProducts } from "@/hooks/data/use-products"
import { useQueryClient } from "@tanstack/react-query"
import { toast } from "sonner"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  CheckCircle2, AlertTriangle, XCircle, Upload, Download,
  FileText, Loader2, ChevronRight, RotateCcw,
} from "lucide-react"
import {
  TEMPLATE_CSV, UI_KEY_TO_DB, UI_KEY_LABEL, ADJUSTMENT_TYPE_LABELS, parseCSVText, parseAndValidate,
  hasMotivoColumn, looksLikeThousandsGrouping, type ParsedImportRow, type RowStatus,
} from "@/lib/stock-import-parser"
import { humanizeOperationError } from "@/lib/operation-errors"
import { formatNumber } from "@/lib/format"
import { cn } from "@/lib/utils"

// ── CSV template (contenido en lib/stock-import-parser, testeado allí) ─────────

function downloadTemplate() {
  const blob = new Blob(["﻿" + TEMPLATE_CSV], { type: "text/csv;charset=utf-8;" })
  const url  = URL.createObjectURL(blob)
  const a    = Object.assign(document.createElement("a"), {
    href: url, download: "template_ajuste_stock.csv",
  })
  a.click()
  URL.revokeObjectURL(url)
}

// ── Conteos y textos de resultado ─────────────────────────────────────────────

/** «1 fila» / «2 filas»: el sustantivo concuerda con el conteo. */
function countLabel(n: number, one: string, many: string): string {
  return `${n} ${n === 1 ? one : many}`
}

/**
 * Fila que NO llegó a la RPC: el parser la bloqueó (motivo faltante, tipo inválido,
 * producto no encontrado…) y `handleApply` la saltea sin tocar el stock. Mismo criterio
 * que el salto de `handleApply` (`status === "error" || !product`): si cambia uno,
 * cambia el otro.
 */
function isOmittedRow(row: ParsedImportRow): boolean {
  return row.applied === false && (row.status === "error" || !row.product)
}

/** Fila que SÍ llegó a la RPC y la RPC rechazó (rol, stock insuficiente, red…). */
function isRejectedRow(row: ParsedImportRow): boolean {
  return row.applied === false && !isOmittedRow(row)
}

interface ApplyOutcome {
  applied: number
  /** Rechazadas por la RPC al aplicar. */
  failed:  number
  /** Bloqueadas por el parser antes de aplicar: no son un error de la RPC. */
  omitted: number
}

function countApplyOutcome(rows: ParsedImportRow[]): ApplyOutcome {
  return {
    applied: rows.filter((r) => r.applied === true).length,
    failed:  rows.filter(isRejectedRow).length,
    omitted: rows.filter(isOmittedRow).length,
  }
}

/** Titular del resultado: el panel del paso 3 y el toast muestran este mismo texto. */
function resultHeadline({ applied, failed, omitted }: ApplyOutcome): string {
  if (failed === 0 && omitted === 0) {
    return `${countLabel(applied, "ajuste registrado", "ajustes registrados")} correctamente`
  }
  if (applied === 0) return "No se pudo aplicar ningún ajuste"
  const parts = [countLabel(applied, "aplicado", "aplicados")]
  if (failed  > 0) parts.push(`${failed} con error`)
  if (omitted > 0) parts.push(countLabel(omitted, "omitida", "omitidas"))
  return parts.join(" · ")
}

/** Aclaración bajo el titular: qué filas quedaron sin aplicar (siempre sin tocar el stock). */
function resultNote({ failed, omitted }: ApplyOutcome): string | null {
  if (failed > 0 && omitted > 0) return "Las filas omitidas o con error no modificaron el stock."
  if (failed  > 0) return "Las filas con error no modificaron el stock."
  if (omitted > 0) return "Las filas omitidas no modificaron el stock."
  return null
}

// ── Status badge ───────────────────────────────────────────────────────────────

function StatusBadge({ status }: { status: RowStatus }) {
  if (status === "ok")
    return <span className="inline-flex items-center gap-1 text-emerald-400 text-xs font-medium"><CheckCircle2 className="h-3.5 w-3.5" />OK</span>
  if (status === "warning")
    return <span className="inline-flex items-center gap-1 text-yellow-400 text-xs font-medium"><AlertTriangle className="h-3.5 w-3.5" />Advertencia</span>
  return   <span className="inline-flex items-center gap-1 text-red-400 text-xs font-medium"><XCircle className="h-3.5 w-3.5" />Error</span>
}

// ── Step indicator ────────────────────────────────────────────────────────────

function StepIndicator({ current }: { current: 1 | 2 | 3 }) {
  const steps = ["Archivo", "Revisión", "Resultado"]
  return (
    <div className="flex items-center gap-1 shrink-0">
      {steps.map((label, i) => {
        const n = i + 1 as 1 | 2 | 3
        const active = n === current
        const done   = n < current
        return (
          <div key={n} className="flex items-center gap-1">
            <div className={cn(
              "flex items-center justify-center w-5 h-5 rounded-full text-[11px] font-semibold",
              done   ? "bg-primary/20 text-primary" :
              active ? "bg-primary text-primary-foreground" :
                       "bg-muted text-muted-foreground",
            )}>
              {done ? <CheckCircle2 className="h-3 w-3" /> : n}
            </div>
            <span className={cn(
              "text-xs hidden sm:inline",
              active ? "text-foreground font-medium" : "text-muted-foreground",
            )}>{label}</span>
            {i < steps.length - 1 && <ChevronRight className="h-3 w-3 text-muted-foreground/40" />}
          </div>
        )
      })}
    </div>
  )
}

// ── Main component ─────────────────────────────────────────────────────────────

interface StockImportAdjustmentDialogProps {
  open:         boolean
  onOpenChange: (open: boolean) => void
  onSuccess?:  () => void
}

type Step = 1 | 2 | 3

export function StockImportAdjustmentDialog({
  open,
  onOpenChange,
  onSuccess,
}: StockImportAdjustmentDialogProps) {
  const { products } = useProducts()
  const queryClient  = useQueryClient()
  const refreshData  = () => queryClient.invalidateQueries()
  const supabase = createClient()

  const [step,     setStep]     = useState<Step>(1)
  const [rows,     setRows]     = useState<ParsedImportRow[]>([])
  const [applying, setApplying] = useState(false)
  const [fileName, setFileName] = useState("")

  const fileRef = useRef<HTMLInputElement>(null)

  // ── Only adjustable products ──────────────────────────────────────────────
  const adjustableProducts = useMemo(
    () => products.filter(
      (p) => p.stockControlType !== "variant_only" && p.stockControlType !== "untracked",
    ),
    [products],
  )

  // ── Summary stats ──────────────────────────────────────────────────────────
  const okCount      = rows.filter((r) => r.status !== "error").length
  const errorCount   = rows.filter((r) => r.status === "error").length
  const warningCount = rows.filter((r) => r.status === "warning").length
  // Resultado (paso 3): aplicadas · rechazadas por la RPC · omitidas por el parser.
  const outcome      = countApplyOutcome(rows)
  const rejectedRows = rows.filter(isRejectedRow)
  const omittedRows  = rows.filter(isOmittedRow)
  const outcomeNote  = resultNote(outcome)

  // ── Reset ──────────────────────────────────────────────────────────────────
  const reset = useCallback(() => {
    setStep(1)
    setRows([])
    setFileName("")
    if (fileRef.current) fileRef.current.value = ""
  }, [])

  // ── File upload ────────────────────────────────────────────────────────────
  const handleFile = useCallback(
    (e: React.ChangeEvent<HTMLInputElement>) => {
      const file = e.target.files?.[0]
      if (!file) return
      setFileName(file.name)

      const reader = new FileReader()
      reader.onload = (ev) => {
        const text = ev.target?.result as string
        const cells = parseCSVText(text)

        if (cells.length < 2) {
          toast.error("El archivo no tiene filas de datos o el formato es incorrecto.")
          return
        }

        // Validate header has required columns
        const header = cells[0].map((h) => h.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""))
        const hasName = header.some((h) => ["nombre", "producto", "name"].includes(h))
        const hasQty  = header.some((h) => ["cantidad", "qty", "quantity"].includes(h))

        if (!hasName || !hasQty) {
          toast.error('El CSV debe tener al menos las columnas "Nombre" y "Cantidad".')
          return
        }

        // stock-ledger-solo-rpc: el motivo es obligatorio. Sin la columna el ARCHIVO
        // se rechaza acá (error de archivo), antes de la vista previa.
        if (!hasMotivoColumn(cells)) {
          toast.error('El CSV debe tener la columna "Motivo": cada ajuste exige un motivo que queda en el historial.')
          return
        }

        const parsed = parseAndValidate(cells, adjustableProducts)
        setRows(parsed)
        setStep(2)
      }
      reader.readAsText(file, "UTF-8")
    },
    [adjustableProducts],
  )

  // ── Apply adjustments ──────────────────────────────────────────────────────
  const handleApply = useCallback(async () => {
    setApplying(true)
    const updated = [...rows]

    for (let i = 0; i < updated.length; i++) {
      const row = updated[i]
      if (row.status === "error" || !row.product) {
        // Skip blocked rows — mark them as not applied
        updated[i] = { ...row, applied: false, applyError: "Fila omitida por errores de validación" }
        continue
      }

      const info   = UI_KEY_TO_DB[row.uiKey] ?? UI_KEY_TO_DB.adjustment_in
      const params: Record<string, unknown> = {
        p_product_id: row.product.id,
        p_type:       info.type,
        p_reason:     row.rawMotivo.trim(),
      }

      if (info.sign === 0) {
        // physical_count: send absolute target quantity (server computes delta with lock)
        params.p_target_quantity = row.quantity
      } else {
        params.p_quantity_delta = row.quantity * info.sign
      }

      const { error } = await supabase.rpc("rpc_stock_adjustment", params)
      if (error) {
        // Mapa canónico (rol, motivo, producto, stock…): castellano accionable, no el
        // `error.message` crudo de PostgREST; si no lo reconoce, lo devuelve tal cual.
        updated[i] = {
          ...row,
          applied: false,
          applyError: humanizeOperationError(
            error.message,
            (id) => products.find((pr) => pr.id === id)?.name,
            undefined,
            { documentLabel: "ajuste de stock" },
          ).message,
        }
      } else {
        updated[i] = { ...row, applied: true }
      }
    }

    setRows(updated)
    setApplying(false)
    setStep(3)
    await refreshData()

    // El toast dice lo mismo que el panel del paso 3 (mismo conteo, mismo texto).
    const result   = countApplyOutcome(updated)
    const headline = resultHeadline(result)

    if (result.failed === 0 && result.omitted === 0) {
      toast.success(headline)
    } else {
      toast.warning(`${headline} — revisá los detalles`)
    }
    // El padre se entera cuando no hubo rechazos de la RPC (las omitidas no tocan el stock).
    if (result.failed === 0) onSuccess?.()
  }, [rows, products, supabase, refreshData, onSuccess])

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) reset(); onOpenChange(v) }}>
      <DialogContent className="bg-card border-border sm:max-w-[680px] max-h-[90vh] flex flex-col gap-0 p-0">

        {/* Header */}
        <div className="flex items-start justify-between gap-4 px-6 pt-6 pb-4 border-b border-border shrink-0">
          <div className="min-w-0">
            <DialogTitle className="text-base font-semibold text-card-foreground">
              Importar ajuste de stock
            </DialogTitle>
            <DialogDescription className="text-sm text-muted-foreground mt-0.5">
              Cargá un CSV con los productos a ajustar
            </DialogDescription>
          </div>
          <StepIndicator current={step} />
        </div>

        {/* Body */}
        <div className="flex-1 overflow-hidden">

          {/* ── STEP 1: Upload ── */}
          {step === 1 && (
            <div className="flex flex-col gap-5 px-6 py-5">

              {/* Drop zone */}
              <label
                htmlFor="csv-upload"
                className={cn(
                  "flex flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed",
                  "border-border bg-muted/20 px-6 py-10 cursor-pointer",
                  "hover:border-primary/40 hover:bg-primary/5 transition-colors",
                )}
              >
                <Upload className="h-8 w-8 text-muted-foreground/50" />
                <div className="text-center">
                  <p className="text-sm font-medium text-foreground">
                    Hacé clic o arrastrá tu archivo CSV
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    CSV con delimitador coma (,) o punto y coma (;) — UTF-8
                  </p>
                </div>
                <input
                  id="csv-upload"
                  ref={fileRef}
                  type="file"
                  accept=".csv,.txt"
                  className="hidden"
                  onChange={handleFile}
                />
              </label>

              {/* Template download */}
              <div className="flex items-center justify-between rounded-lg border border-border bg-muted/30 px-4 py-3">
                <div className="flex items-center gap-3">
                  <FileText className="h-4 w-4 text-muted-foreground shrink-0" />
                  <div>
                    <p className="text-sm font-medium text-foreground">Template de ejemplo</p>
                    <p className="text-xs text-muted-foreground">Formato correcto con filas de muestra</p>
                  </div>
                </div>
                <Button variant="outline" size="sm" className="gap-1.5 shrink-0" onClick={downloadTemplate}>
                  <Download className="h-3.5 w-3.5" />
                  Descargar
                </Button>
              </div>

              {/* Column reference */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Columnas del CSV
                </p>
                <div className="grid grid-cols-2 gap-x-6 gap-y-1 text-xs">
                  <div><span className="font-medium text-foreground">Nombre</span> <span className="text-muted-foreground">(obligatorio)</span></div>
                  <div><span className="font-medium text-foreground">Cantidad</span> <span className="text-muted-foreground">(obligatorio — decimales con coma o punto)</span></div>
                  <div><span className="font-medium text-foreground">Tipo</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Motivo</span> <span className="text-muted-foreground">(obligatorio — queda en el historial)</span></div>
                </div>
              </div>

              {/* Type reference */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Valores válidos para la columna Tipo
                </p>
                <div className="grid grid-cols-2 gap-x-6 gap-y-1 text-xs text-muted-foreground">
                  {ADJUSTMENT_TYPE_LABELS.map((label) => (
                    <div key={label}>{label}</div>
                  ))}
                </div>
                <p className="text-[11px] text-muted-foreground/60">
                  Para mover mercadería entre sucursales usá «Transferir stock»: no es un ajuste.
                </p>
                <p className="text-[11px] text-muted-foreground/60">
                  Si omitís la columna Tipo, se usará "Ajuste entrada" por defecto.
                </p>
              </div>
            </div>
          )}

          {/* ── STEP 2: Preview ── */}
          {step === 2 && (
            <div className="flex flex-col h-full">

              {/* Summary bar */}
              <div className="flex items-center gap-3 px-6 py-3 border-b border-border bg-muted/10 shrink-0 flex-wrap">
                <span className="text-xs text-muted-foreground">
                  <span className="font-medium text-foreground">{countLabel(rows.length, "fila", "filas")}</span> · Archivo: {fileName}
                </span>
                <div className="flex items-center gap-2 ml-auto flex-wrap">
                  {okCount > 0      && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30 text-xs">{okCount - warningCount} OK</Badge>}
                  {warningCount > 0 && <Badge variant="outline" className="text-yellow-400 border-yellow-500/30 text-xs">{countLabel(warningCount, "advertencia", "advertencias")}</Badge>}
                  {errorCount > 0   && <Badge variant="outline" className="text-red-400 border-red-500/30 text-xs">{countLabel(errorCount, "error", "errores")}</Badge>}
                </div>
              </div>

              {/* Table */}
              <ScrollArea className="flex-1 h-[320px]">
                <div className="px-4 py-2">
                  {/* Desktop header */}
                  <div className="hidden sm:grid grid-cols-[32px_1fr_130px_80px_80px] gap-2 px-2 py-1.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide border-b border-border/50 sticky top-0 bg-card z-10">
                    <span>#</span>
                    <span>Producto</span>
                    <span>Tipo</span>
                    <span>Cantidad</span>
                    <span>Estado</span>
                  </div>

                  {rows.map((row) => (
                    <div
                      key={row.rowNum}
                      className={cn(
                        "grid sm:grid-cols-[32px_1fr_130px_80px_80px] gap-2 px-2 py-2.5 border-b border-border/40 last:border-0 items-start",
                        row.status === "error"   && "bg-red-500/5",
                        row.status === "warning" && "bg-yellow-500/5",
                      )}
                    >
                      {/* Row number */}
                      <span className="text-[11px] text-muted-foreground tabular-nums pt-0.5 hidden sm:block">
                        {row.rowNum}
                      </span>

                      {/* Product + messages */}
                      <div className="min-w-0 col-span-4 sm:col-span-1">
                        <p className="text-sm font-medium text-foreground truncate">
                          {row.resolvedName ?? row.rawName}
                        </p>
                        {row.rawName !== row.resolvedName && row.resolvedName && (
                          <p className="text-[11px] text-muted-foreground truncate">
                            CSV: &ldquo;{row.rawName}&rdquo;
                          </p>
                        )}
                        {row.errors.map((e, i) => (
                          <p key={i} className="text-[11px] text-red-400 flex items-center gap-1 mt-0.5">
                            <XCircle className="h-3 w-3 shrink-0" />{e}
                          </p>
                        ))}
                        {row.warnings.map((w, i) => (
                          <p key={i} className="text-[11px] text-yellow-400 flex items-center gap-1 mt-0.5">
                            <AlertTriangle className="h-3 w-3 shrink-0" />{w}
                          </p>
                        ))}
                      </div>

                      {/* Type */}
                      <span className="text-xs text-muted-foreground hidden sm:block pt-0.5">
                        {UI_KEY_LABEL[row.uiKey] ?? row.rawType}
                      </span>

                      {/* Quantity — la interpretada, con los 4 decimales que admite la RPC
                          (numeric(15,4)); el texto del CSV al lado sólo cuando podría
                          haberse leído como miles, como con el nombre parcial */}
                      <div className="min-w-0 text-xs tabular-nums font-medium text-foreground hidden sm:block pt-0.5">
                        {row.quantityValid ? formatNumber(row.quantity, 4) : row.rawQuantity}
                        {row.quantityValid && looksLikeThousandsGrouping(row.rawQuantity) && (
                          <p className="text-[11px] font-normal text-muted-foreground truncate">
                            CSV: &ldquo;{row.rawQuantity}&rdquo;
                          </p>
                        )}
                      </div>

                      {/* Status */}
                      <div className="hidden sm:block pt-0.5">
                        <StatusBadge status={row.status} />
                      </div>
                    </div>
                  ))}
                </div>
              </ScrollArea>

              {errorCount > 0 && (
                <div className="px-6 py-2.5 border-t border-border bg-muted/10 shrink-0">
                  <p className="text-xs text-muted-foreground">
                    <span className="text-red-400 font-medium">{countLabel(errorCount, "fila", "filas")} con error</span>
                    {" "}— {errorCount === 1 ? "se omitirá" : "se omitirán"} al confirmar.
                    {okCount === 1 && <span> Se aplicará la fila válida.</span>}
                    {okCount > 1 && <span> Se aplicarán las <span className="font-medium text-foreground">{okCount}</span> filas válidas.</span>}
                  </p>
                </div>
              )}
            </div>
          )}

          {/* ── STEP 3: Result ── */}
          {step === 3 && (
            <div className="flex flex-col h-full">

              {/* Summary */}
              <div className="flex flex-col items-center justify-center gap-3 px-6 py-6 border-b border-border shrink-0">
                {outcome.failed === 0 && outcome.omitted === 0 ? (
                  <CheckCircle2 className="h-10 w-10 text-emerald-400" />
                ) : outcome.applied === 0 ? (
                  <XCircle className="h-10 w-10 text-red-400" />
                ) : (
                  <AlertTriangle className="h-10 w-10 text-yellow-400" />
                )}
                <div className="text-center">
                  <p className="text-base font-semibold text-foreground">
                    {resultHeadline(outcome)}
                  </p>
                  {outcomeNote && (
                    <p className="text-sm text-muted-foreground mt-1">
                      {outcomeNote}
                    </p>
                  )}
                </div>
                <div className="flex items-center gap-2">
                  {outcome.applied > 0 && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30">{countLabel(outcome.applied, "aplicado", "aplicados")}</Badge>}
                  {outcome.omitted > 0 && <Badge variant="outline" className="text-yellow-400 border-yellow-500/30">{countLabel(outcome.omitted, "omitida", "omitidas")}</Badge>}
                  {outcome.failed  > 0 && <Badge variant="outline" className="text-red-400 border-red-500/30">{countLabel(outcome.failed, "error", "errores")}</Badge>}
                </div>
              </div>

              {/* Row results — cada fila que no se aplicó figura con su motivo */}
              {(rejectedRows.length > 0 || omittedRows.length > 0) && (
                <ScrollArea className="flex-1 h-[220px]">
                  <div className="px-6 py-3 flex flex-col gap-4">
                    {rejectedRows.length > 0 && (
                      <div className="flex flex-col gap-1.5">
                        <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mb-1">
                          Detalle de errores
                        </p>
                        {rejectedRows.map((row) => (
                          <div key={row.rowNum} className="flex items-start gap-2 text-xs">
                            <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">Fila {row.rowNum}</span>
                            <span className="font-medium text-foreground shrink-0">{row.resolvedName ?? row.rawName}</span>
                            <span className="text-red-400">{row.applyError}</span>
                          </div>
                        ))}
                      </div>
                    )}
                    {omittedRows.length > 0 && (
                      <div className="flex flex-col gap-1.5">
                        <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mb-1">
                          Filas omitidas
                        </p>
                        {omittedRows.map((row) => (
                          <div key={row.rowNum} className="flex items-start gap-2 text-xs">
                            <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">Fila {row.rowNum}</span>
                            <span className="font-medium text-foreground shrink-0">{row.resolvedName ?? row.rawName}</span>
                            <span className="flex flex-col text-yellow-400">
                              {row.errors.map((e) => <span key={e}>{e}</span>)}
                            </span>
                          </div>
                        ))}
                      </div>
                    )}
                  </div>
                </ScrollArea>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="shrink-0 flex items-center justify-between gap-2 px-6 py-4 border-t border-border">
          <div>
            {step === 2 && (
              <Button variant="ghost" size="sm" onClick={() => setStep(1)} disabled={applying} className="gap-1.5">
                <RotateCcw className="h-3.5 w-3.5" />
                Cambiar archivo
              </Button>
            )}
          </div>

          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => { reset(); onOpenChange(false) }}
              disabled={applying}
            >
              {step === 3 ? "Cerrar" : "Cancelar"}
            </Button>

            {step === 2 && (
              <Button
                size="sm"
                onClick={handleApply}
                disabled={applying || okCount === 0}
                className="gap-1.5"
              >
                {applying ? (
                  <><Loader2 className="h-3.5 w-3.5 animate-spin" />Aplicando…</>
                ) : (
                  <>Aplicar {countLabel(okCount, "ajuste", "ajustes")}</>
                )}
              </Button>
            )}

            {step === 3 && (outcome.failed > 0 || outcome.omitted > 0) && (
              <Button size="sm" variant="outline" onClick={reset} className="gap-1.5">
                <RotateCcw className="h-3.5 w-3.5" />
                Importar otro archivo
              </Button>
            )}
          </div>
        </div>

      </DialogContent>
    </Dialog>
  )
}
