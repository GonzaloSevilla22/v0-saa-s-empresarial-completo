"use client"

/**
 * ProductImportDialog
 *
 * 3-step import wizard for CSV product files.
 * Supports: standalone products, parent catalogue entries, and variants.
 *
 * Step 1 — Upload
 *   Drop/select a .csv file. Shows a downloadable template and the supported
 *   column reference. Auto-detects comma/semicolon delimiter, strips UTF-8 BOM.
 *
 * Step 2 — Preview & validation
 *   Parses and validates each row hierarchically (Padre → Variante → Producto).
 *   Shows per-row badges (OK / ⚠ Advertencia / ✕ Error). Rows with errors are
 *   counted and will be skipped. User can confirm even when warnings exist.
 *
 * Step 3 — Result
 *   Applies the import and shows a summary: N new · M updated · K errors.
 *   If server errors occurred, shows a scrollable error detail list.
 */

import { useState, useRef, useCallback } from "react"
import { toast } from "sonner"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { Badge } from "@/components/ui/badge"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  Upload, FileText, AlertTriangle, CheckCircle2, XCircle,
  ChevronRight, Loader2, Download, RotateCcw,
} from "lucide-react"
import { useAuth } from "@/contexts/auth-context"
import { parseImportFile }    from "@/lib/import/parser"
import { validateImportRows } from "@/lib/import/validator"
import {
  importProductsFromFile,
  type ImportProgressCallback,
} from "@/lib/import/importer"
import type { ValidatedImportRow, ImportResult } from "@/lib/import/types"
import { cn } from "@/lib/utils"

// ── CSV template ───────────────────────────────────────────────────────────────

const TEMPLATE_CSV = [
  "Tipo;Nombre;Precio;Costo;Categoría;Stock;Stock mínimo;Código;SKU",
  "Producto;Remera básica;5000;2500;Ropa;50;10;;REM-001",
  "Padre;Zapatillas Nike;;;;;;; ZAP-NIKE",
  "Variante;Zapatillas Nike 41;18000;9000;Ropa;15;3;;ZAP-NIKE-41",
  "Variante;Zapatillas Nike 42;18000;9000;Ropa;12;3;;ZAP-NIKE-42",
  "Producto;Aceite de oliva 500ml;3200;1800;Alimentos;30;5;7790001234567;ACE-500",
].join("\n")

function downloadTemplate() {
  const blob = new Blob(["﻿" + TEMPLATE_CSV], { type: "text/csv;charset=utf-8;" })
  const url  = URL.createObjectURL(blob)
  const a    = Object.assign(document.createElement("a"), {
    href: url, download: "template_productos.csv",
  })
  a.click()
  URL.revokeObjectURL(url)
}

// ── Step indicator ─────────────────────────────────────────────────────────────

function StepIndicator({ current }: { current: 1 | 2 | 3 }) {
  const steps = ["Archivo", "Revisión", "Resultado"]
  return (
    <div className="flex items-center gap-1 shrink-0">
      {steps.map((label, i) => {
        const n      = (i + 1) as 1 | 2 | 3
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

// ── Row status badge ───────────────────────────────────────────────────────────

function RowStatusIcon({ row }: { row: ValidatedImportRow }) {
  const hasError   = row.errors.length > 0
  const hasWarning = !hasError && row.warnings.length > 0
  if (hasError)   return <XCircle   className="h-3.5 w-3.5 text-red-400 mt-0.5 shrink-0" />
  if (hasWarning) return <AlertTriangle className="h-3.5 w-3.5 text-yellow-400 mt-0.5 shrink-0" />
  return              <CheckCircle2 className="h-3.5 w-3.5 text-emerald-400 mt-0.5 shrink-0" />
}

// ── Component props ────────────────────────────────────────────────────────────

interface ProductImportDialogProps {
  open:         boolean
  onOpenChange: (open: boolean) => void
  onComplete:   () => void
}

type Step = 1 | 2 | 3

interface PreviewSummary {
  parents:    number
  variants:   number
  standalone: number
  errors:     number
  warnings:   number
  rows:       ValidatedImportRow[]
}

// ── Main component ─────────────────────────────────────────────────────────────

export function ProductImportDialog({
  open,
  onOpenChange,
  onComplete,
}: ProductImportDialogProps) {
  const { user } = useAuth()

  const [step,          setStep]         = useState<Step>(1)
  const [file,          setFile]         = useState<File | null>(null)
  const [fileName,      setFileName]     = useState("")
  const [preview,       setPreview]      = useState<PreviewSummary | null>(null)
  const [result,        setResult]       = useState<ImportResult | null>(null)
  const [importing,     setImporting]    = useState(false)
  const [progress,      setProgress]     = useState(0)
  const [progressLabel, setProgressLabel] = useState("")
  const [dragOver,      setDragOver]     = useState(false)

  const fileInputRef = useRef<HTMLInputElement | null>(null)

  // ── Reset ──────────────────────────────────────────────────────────────────
  const reset = useCallback(() => {
    setStep(1)
    setFile(null)
    setFileName("")
    setPreview(null)
    setResult(null)
    setImporting(false)
    setProgress(0)
    setDragOver(false)
    if (fileInputRef.current) fileInputRef.current.value = ""
  }, [])

  function handleOpenChange(v: boolean) {
    if (!v) reset()
    onOpenChange(v)
  }

  // ── File selection ──────────────────────────────────────────────────────────
  const handleFile = useCallback(async (selected: File) => {
    setFile(selected)
    setFileName(selected.name)
    setStep(2)

    const parsed = await parseImportFile(selected)
    if (!parsed.ok) {
      toast.error(parsed.error)
      setStep(1)
      return
    }

    const { rows, invalidCount, warningCount, parentCount, variantCount, standaloneCount } =
      validateImportRows(parsed.rows)

    setPreview({
      parents:    parentCount,
      variants:   variantCount,
      standalone: standaloneCount,
      errors:     invalidCount,
      warnings:   warningCount,
      rows,
    })
  }, [])

  function handleDrop(e: React.DragEvent) {
    e.preventDefault()
    setDragOver(false)
    const dropped = e.dataTransfer.files[0]
    if (dropped) handleFile(dropped)
  }

  function handleInputChange(e: React.ChangeEvent<HTMLInputElement>) {
    const selected = e.target.files?.[0]
    if (selected) handleFile(selected)
  }

  // ── Import ──────────────────────────────────────────────────────────────────
  const handleImport = useCallback(async () => {
    if (!file || !user) return
    setImporting(true)

    const onProgress: ImportProgressCallback = ({ phase, done, total }) => {
      const pct = total > 0 ? Math.round((done / total) * 100) : 0
      setProgress(pct)
      setProgressLabel(
        phase === "parsing"    ? "Leyendo archivo…"        :
        phase === "validating" ? "Validando filas…"        :
        phase === "resolving"  ? "Resolviendo jerarquías…" :
                                 `Importando… ${done}/${total}`,
      )
    }

    try {
      const importResult = await importProductsFromFile({ file, userId: user.id, onProgress })
      setResult(importResult)
      setStep(3)
      onComplete()

      const totalOk = importResult.inserted + importResult.updated
      if (totalOk > 0) {
        toast.success(`${totalOk} producto${totalOk !== 1 ? "s" : ""} importado${totalOk !== 1 ? "s" : ""} correctamente`)
      }
    } catch (err: any) {
      toast.error(err?.message ?? "Error al importar.")
    } finally {
      setImporting(false)
    }
  }, [file, user, onComplete])

  // ── Derived stats ──────────────────────────────────────────────────────────
  const validCount = preview?.rows.filter((r) => r.errors.length === 0).length ?? 0
  const totalOk    = (result?.inserted ?? 0) + (result?.updated ?? 0)
  const totalErr   = (result?.validationErrors.length ?? 0) + (result?.dbErrors.length ?? 0)

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="bg-card border-border sm:max-w-[680px] max-h-[90vh] flex flex-col gap-0 p-0">

        {/* Header */}
        <div className="flex items-start justify-between gap-4 px-6 pt-6 pb-4 border-b border-border shrink-0">
          <div className="min-w-0">
            <DialogTitle className="text-base font-semibold text-card-foreground">
              Importar productos desde CSV
            </DialogTitle>
            <DialogDescription className="text-sm text-muted-foreground mt-0.5">
              Soporta productos simples, catálogos padre y variantes
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
              <div
                onDragOver={(e) => { e.preventDefault(); setDragOver(true) }}
                onDragLeave={() => setDragOver(false)}
                onDrop={handleDrop}
                onClick={() => fileInputRef.current?.click()}
                className={cn(
                  "flex flex-col items-center justify-center gap-3 rounded-xl border-2 border-dashed",
                  "px-6 py-10 cursor-pointer transition-colors",
                  dragOver
                    ? "border-primary bg-primary/10"
                    : "border-border bg-muted/20 hover:border-primary/40 hover:bg-primary/5",
                )}
              >
                <Upload className="h-8 w-8 text-muted-foreground/50" />
                <div className="text-center">
                  <p className="text-sm font-medium text-foreground">
                    Hacé clic o arrastrá tu archivo CSV
                  </p>
                  <p className="text-xs text-muted-foreground mt-1">
                    CSV con delimitador coma (,) o punto y coma (;) — UTF-8 · Máx. 10 MB
                  </p>
                </div>
                <input
                  ref={fileInputRef}
                  type="file"
                  accept=".csv,.txt"
                  className="hidden"
                  onChange={handleInputChange}
                />
              </div>

              {/* Template download */}
              <div className="flex items-center justify-between rounded-lg border border-border bg-muted/30 px-4 py-3">
                <div className="flex items-center gap-3">
                  <FileText className="h-4 w-4 text-muted-foreground shrink-0" />
                  <div>
                    <p className="text-sm font-medium text-foreground">Template de ejemplo</p>
                    <p className="text-xs text-muted-foreground">Incluye filas de Producto, Padre y Variante</p>
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
                <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-xs">
                  <div><span className="font-medium text-foreground">Nombre</span> <span className="text-muted-foreground">(obligatorio)</span></div>
                  <div><span className="font-medium text-foreground">Precio</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Costo</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Categoría</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Stock</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Stock mínimo</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Código</span> <span className="text-muted-foreground">(código de barras)</span></div>
                  <div><span className="font-medium text-foreground">SKU</span> <span className="text-muted-foreground">(opcional)</span></div>
                </div>
              </div>

              {/* Type reference */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Columna Tipo
                </p>
                <div className="flex flex-wrap gap-2">
                  {["Producto", "Padre", "Variante"].map((t) => (
                    <span key={t} className="text-xs px-2 py-0.5 rounded bg-muted font-medium text-foreground">{t}</span>
                  ))}
                </div>
                <p className="text-[11px] text-muted-foreground/60">
                  Si omitís la columna Tipo, todas las filas se importan como productos simples.
                  Las variantes se asocian automáticamente al Padre más cercano en el archivo.
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
                  {preview
                    ? <><span className="font-medium text-foreground">{preview.rows.length}</span> filas · {fileName}</>
                    : <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Analizando…</span>
                  }
                </span>
                {preview && (
                  <div className="flex items-center gap-2 ml-auto flex-wrap">
                    {preview.standalone > 0 && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30 text-xs">{preview.standalone} simple{preview.standalone !== 1 ? "s" : ""}</Badge>}
                    {preview.parents    > 0 && <Badge variant="outline" className="text-blue-400 border-blue-500/30 text-xs">{preview.parents} padre{preview.parents !== 1 ? "s" : ""}</Badge>}
                    {preview.variants   > 0 && <Badge variant="outline" className="text-purple-400 border-purple-500/30 text-xs">{preview.variants} variante{preview.variants !== 1 ? "s" : ""}</Badge>}
                    {preview.warnings   > 0 && <Badge variant="outline" className="text-yellow-400 border-yellow-500/30 text-xs">{preview.warnings} advertencia{preview.warnings !== 1 ? "s" : ""}</Badge>}
                    {preview.errors     > 0 && <Badge variant="outline" className="text-red-400 border-red-500/30 text-xs">{preview.errors} error{preview.errors !== 1 ? "es" : ""}</Badge>}
                  </div>
                )}
              </div>

              {/* Parsing spinner */}
              {!preview && (
                <div className="flex flex-col items-center justify-center gap-3 py-16 text-muted-foreground">
                  <Loader2 className="h-8 w-8 animate-spin text-primary" />
                  <p className="text-sm">Analizando archivo…</p>
                </div>
              )}

              {/* Row list */}
              {preview && (
                <ScrollArea className="flex-1 h-[320px]">
                  <div className="px-4 py-2 space-y-0.5">
                    {preview.rows.map((row) => {
                      const hasError   = row.errors.length > 0
                      const hasWarning = !hasError && row.warnings.length > 0
                      const typeLabel  = row.rowType === "Padre"    ? "PADRE"    :
                                         row.rowType === "Variante" ? "VARIANTE" : "PRODUCTO"
                      const typeColor  = row.rowType === "Padre"    ? "text-blue-400"   :
                                         row.rowType === "Variante" ? "text-purple-400" : "text-emerald-400"
                      return (
                        <div
                          key={row.lineNumber}
                          className={cn(
                            "flex items-start gap-2 px-2 py-2 rounded text-xs",
                            hasError   ? "bg-red-500/5"    : "",
                            hasWarning ? "bg-yellow-500/5" : "",
                          )}
                        >
                          <RowStatusIcon row={row} />
                          <div className="min-w-0 flex-1">
                            <div className="flex items-baseline gap-1.5">
                              <span className={cn("font-semibold text-[11px] uppercase tracking-wide shrink-0", typeColor)}>
                                [{typeLabel}]
                              </span>
                              <span className="font-medium text-foreground truncate">
                                {row.name || <em className="text-muted-foreground font-normal">sin nombre</em>}
                              </span>
                              {row.sku && (
                                <span className="text-muted-foreground shrink-0">SKU: {row.sku}</span>
                              )}
                            </div>
                            {(row.errors.length > 0 || row.warnings.length > 0) && (
                              <div className="mt-0.5 space-y-0.5">
                                {row.errors.map((e, i) => (
                                  <p key={i} className="text-red-400 flex items-center gap-1">
                                    <XCircle className="h-2.5 w-2.5 shrink-0" />{e}
                                  </p>
                                ))}
                                {row.warnings.map((w, i) => (
                                  <p key={i} className="text-yellow-400 flex items-center gap-1">
                                    <AlertTriangle className="h-2.5 w-2.5 shrink-0" />{w}
                                  </p>
                                ))}
                              </div>
                            )}
                          </div>
                          <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">L{row.lineNumber}</span>
                        </div>
                      )
                    })}
                  </div>
                </ScrollArea>
              )}

              {/* Importing progress overlay */}
              {importing && (
                <div className="absolute inset-0 flex flex-col items-center justify-center gap-4 bg-card/90 backdrop-blur-sm z-20 rounded-b-lg">
                  <Loader2 className="h-8 w-8 animate-spin text-primary" />
                  <p className="text-sm text-muted-foreground">{progressLabel}</p>
                  <div className="w-56">
                    <Progress value={progress} className="h-1.5" />
                    <p className="text-center text-xs text-muted-foreground mt-1">{progress}%</p>
                  </div>
                </div>
              )}

              {preview && preview.errors > 0 && (
                <div className="px-6 py-2.5 border-t border-border bg-muted/10 shrink-0">
                  <p className="text-xs text-muted-foreground">
                    <span className="text-red-400 font-medium">{preview.errors} fila{preview.errors !== 1 ? "s" : ""} con error</span>
                    {" "}— se omitirán al importar.
                    {validCount > 0 && <span> Se importarán las <span className="font-medium text-foreground">{validCount}</span> filas válidas.</span>}
                  </p>
                </div>
              )}
            </div>
          )}

          {/* ── STEP 3: Result ── */}
          {step === 3 && result && (
            <div className="flex flex-col h-full">
              <div className="flex flex-col items-center justify-center gap-3 px-6 py-6 border-b border-border shrink-0">
                {totalErr === 0 ? (
                  <CheckCircle2 className="h-10 w-10 text-emerald-400" />
                ) : totalOk === 0 ? (
                  <XCircle className="h-10 w-10 text-red-400" />
                ) : (
                  <AlertTriangle className="h-10 w-10 text-yellow-400" />
                )}
                <div className="text-center">
                  <p className="text-base font-semibold text-foreground">
                    {totalErr === 0
                      ? `${totalOk} producto${totalOk !== 1 ? "s" : ""} importado${totalOk !== 1 ? "s" : ""} correctamente`
                      : totalOk === 0
                      ? "No se pudo importar ningún producto"
                      : `${totalOk} OK · ${totalErr} con error`}
                  </p>
                  {totalErr > 0 && (
                    <p className="text-sm text-muted-foreground mt-1">
                      Las filas con error no fueron importadas.
                    </p>
                  )}
                </div>
                <div className="flex flex-wrap items-center justify-center gap-2">
                  {result.inserted  > 0 && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30">{result.inserted} nuevo{result.inserted !== 1 ? "s" : ""}</Badge>}
                  {result.updated   > 0 && <Badge variant="outline" className="text-blue-400 border-blue-500/30">{result.updated} actualizado{result.updated !== 1 ? "s" : ""}</Badge>}
                  {result.parents   > 0 && <Badge variant="outline" className="text-blue-400 border-blue-500/30">{result.parents} padre{result.parents !== 1 ? "s" : ""}</Badge>}
                  {result.variants  > 0 && <Badge variant="outline" className="text-purple-400 border-purple-500/30">{result.variants} variante{result.variants !== 1 ? "s" : ""}</Badge>}
                  {result.standalone > 0 && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30">{result.standalone} simple{result.standalone !== 1 ? "s" : ""}</Badge>}
                  {totalErr         > 0 && <Badge variant="outline" className="text-red-400 border-red-500/30">{totalErr} error{totalErr !== 1 ? "es" : ""}</Badge>}
                </div>
                {totalOk === 0 && totalErr === 0 && (
                  <p className="text-sm text-muted-foreground">
                    No hubo cambios — todos los productos ya existían con los mismos valores.
                  </p>
                )}
              </div>

              {totalErr > 0 && (
                <ScrollArea className="flex-1 h-[220px]">
                  <div className="px-6 py-3 flex flex-col gap-1.5">
                    <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mb-1">
                      Detalle de errores
                    </p>
                    {[...result.validationErrors, ...result.dbErrors].map((e, i) => (
                      <div key={i} className="flex items-start gap-2 text-xs">
                        {e.lineNumber > 0 && (
                          <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">L{e.lineNumber}</span>
                        )}
                        {e.name && (
                          <span className="font-medium text-foreground shrink-0 truncate max-w-[160px]">{e.name}</span>
                        )}
                        <span className="text-red-400">{e.message}</span>
                      </div>
                    ))}
                  </div>
                </ScrollArea>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        <div className="shrink-0 flex items-center justify-between gap-2 px-6 py-4 border-t border-border relative z-30">
          <div>
            {step === 2 && !importing && (
              <Button variant="ghost" size="sm" onClick={() => setStep(1)} className="gap-1.5">
                <RotateCcw className="h-3.5 w-3.5" />
                Cambiar archivo
              </Button>
            )}
          </div>

          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => handleOpenChange(false)}
              disabled={importing}
            >
              {step === 3 ? "Cerrar" : "Cancelar"}
            </Button>

            {step === 2 && preview && (
              <Button
                size="sm"
                onClick={handleImport}
                disabled={importing || validCount === 0}
                className="gap-1.5"
              >
                {importing ? (
                  <><Loader2 className="h-3.5 w-3.5 animate-spin" />Importando…</>
                ) : (
                  <>Importar {validCount} fila{validCount !== 1 ? "s" : ""}</>
                )}
              </Button>
            )}

            {step === 3 && (
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
