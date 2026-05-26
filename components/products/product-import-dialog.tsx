"use client"

/**
 * ProductImportDialog
 *
 * Multi-step import wizard for CSV/XLSX product files.
 * Supports: standalone products, parent catalogue entries, and variants.
 *
 * Steps:
 *   1. Upload   — drop/select file
 *   2. Preview  — hierarchical preview with inline errors and warnings
 *   3. Result   — summary of what was imported
 */

import { useState, useRef, useCallback } from "react"
import { toast } from "sonner"
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Progress } from "@/components/ui/progress"
import { Badge } from "@/components/ui/badge"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  Upload,
  FileText,
  AlertTriangle,
  CheckCircle2,
  XCircle,
  ChevronRight,
  Loader2,
} from "lucide-react"
import { useAuth } from "@/contexts/auth-context"
import { parseImportFile }    from "@/lib/import/parser"
import { validateImportRows } from "@/lib/import/validator"
import { resolveHierarchy }   from "@/lib/import/resolver"
import {
  importProductsFromFile,
  type ImportProgressCallback,
} from "@/lib/import/importer"
import type { ValidatedImportRow, ImportResult } from "@/lib/import/types"

// ─── Types ────────────────────────────────────────────────────────────────────

type Step = "upload" | "preview" | "importing" | "result"

interface PreviewSummary {
  parents:    number
  variants:   number
  standalone: number
  errors:     number
  warnings:   number
  rows:       ValidatedImportRow[]
}

// ─── Component ────────────────────────────────────────────────────────────────

interface ProductImportDialogProps {
  open:       boolean
  onOpenChange: (open: boolean) => void
  onComplete: () => void   // called after a successful import to refresh data
}

export function ProductImportDialog({
  open,
  onOpenChange,
  onComplete,
}: ProductImportDialogProps) {
  const { user } = useAuth()

  const [step,         setStep]        = useState<Step>("upload")
  const [file,         setFile]        = useState<File | null>(null)
  const [preview,      setPreview]     = useState<PreviewSummary | null>(null)
  const [result,       setResult]      = useState<ImportResult | null>(null)
  const [progress,     setProgress]    = useState(0)
  const [progressLabel, setProgressLabel] = useState("")
  const [dragOver,     setDragOver]   = useState(false)
  const fileInputRef = useRef<HTMLInputElement | null>(null)

  // ── Reset on close ──────────────────────────────────────────────────────────
  function handleOpenChange(v: boolean) {
    if (!v) {
      setStep("upload")
      setFile(null)
      setPreview(null)
      setResult(null)
      setProgress(0)
      if (fileInputRef.current) fileInputRef.current.value = ""
    }
    onOpenChange(v)
  }

  // ── File selection ──────────────────────────────────────────────────────────
  async function handleFile(selected: File) {
    setFile(selected)
    setStep("preview")

    const parsed = await parseImportFile(selected)
    if (!parsed.ok) {
      toast.error(parsed.error)
      setStep("upload")
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
  }

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
  async function handleImport() {
    if (!file || !user) return

    setStep("importing")

    const onProgress: ImportProgressCallback = ({ phase, done, total }) => {
      const pct = total > 0 ? Math.round((done / total) * 100) : 0
      setProgress(pct)
      setProgressLabel(
        phase === "parsing"    ? "Leyendo archivo…"        :
        phase === "validating" ? "Validando filas…"        :
        phase === "resolving"  ? "Resolviendo jerarquías…" :
                                 `Importando… ${done}/${total}`
      )
    }

    try {
      const importResult = await importProductsFromFile({
        file,
        userId: user.id,
        onProgress,
      })
      setResult(importResult)
      setStep("result")
      onComplete()
    } catch (err: any) {
      toast.error(err?.message ?? "Error al importar.")
      setStep("preview")
    }
  }

  // ─────────────────────────────────────────────────────────────────────────────

  return (
    <Dialog open={open} onOpenChange={handleOpenChange}>
      <DialogContent className="bg-card border-border max-w-2xl">
        <DialogHeader>
          <DialogTitle className="text-card-foreground flex items-center gap-2">
            <FileText className="h-5 w-5 text-primary" />
            Importar productos desde CSV
          </DialogTitle>
        </DialogHeader>

        {step === "upload"    && <UploadStep      onFile={handleFile} dragOver={dragOver} setDragOver={setDragOver} fileInputRef={fileInputRef} handleInputChange={handleInputChange} onDrop={handleDrop} />}
        {step === "preview"   && preview && <PreviewStep preview={preview} onImport={handleImport} onCancel={() => handleOpenChange(false)} />}
        {step === "importing" && <ImportingStep progress={progress} label={progressLabel} />}
        {step === "result"    && result  && <ResultStep result={result} onClose={() => handleOpenChange(false)} />}
      </DialogContent>
    </Dialog>
  )
}

// ─── Step: Upload ─────────────────────────────────────────────────────────────

function UploadStep({
  onFile, dragOver, setDragOver, fileInputRef, handleInputChange, onDrop,
}: {
  onFile: (f: File) => void
  dragOver: boolean
  setDragOver: (v: boolean) => void
  fileInputRef: React.RefObject<HTMLInputElement | null>
  handleInputChange: (e: React.ChangeEvent<HTMLInputElement>) => void
  onDrop: (e: React.DragEvent) => void
}) {
  return (
    <div className="space-y-4">
      <div
        onDragOver={(e) => { e.preventDefault(); setDragOver(true) }}
        onDragLeave={() => setDragOver(false)}
        onDrop={onDrop}
        onClick={() => fileInputRef.current?.click()}
        className={`
          border-2 border-dashed rounded-lg p-10 text-center cursor-pointer transition-colors
          ${dragOver
            ? "border-primary bg-primary/10"
            : "border-border hover:border-primary/50 hover:bg-muted/40"
          }
        `}
      >
        <Upload className="mx-auto h-10 w-10 text-muted-foreground mb-3" />
        <p className="text-sm font-medium text-foreground">
          Arrastrá tu archivo CSV o hacé clic para seleccionarlo
        </p>
        <p className="text-xs text-muted-foreground mt-1">
          Máximo 10 MB · Separador ; o , · UTF-8
        </p>
        <input
          ref={fileInputRef}
          type="file"
          accept=".csv,.txt"
          className="hidden"
          onChange={handleInputChange}
        />
      </div>

      {/* Template download hint */}
      <div className="rounded-md border border-border bg-muted/30 p-3 text-xs text-muted-foreground space-y-1">
        <p className="font-medium text-foreground">Formato del archivo</p>
        <p>Columnas soportadas: <code>Tipo, Nombre, Precio, Costo, Categoría, Stock, Código, SKU, SKU Padre, Producto Padre, Atributo: Color…</code></p>
        <p><strong>Solo el Nombre es obligatorio.</strong> SKU es opcional en todos los tipos.</p>
        <p><strong>Tipo</strong>: <code>Padre</code> · <code>Variante</code> · <code>Producto</code> o vacío. Las variantes se asocian automáticamente al Padre más cercano en el archivo.</p>
      </div>
    </div>
  )
}

// ─── Step: Preview ────────────────────────────────────────────────────────────

function PreviewStep({
  preview, onImport, onCancel,
}: {
  preview: PreviewSummary
  onImport: () => void
  onCancel: () => void
}) {
  const validCount = preview.rows.filter((r) => r.errors.length === 0).length
  const hasErrors  = preview.errors > 0
  const canImport  = validCount > 0

  return (
    <div className="space-y-4">
      {/* Summary chips */}
      <div className="flex flex-wrap gap-2">
        {preview.standalone > 0 && (
          <Badge variant="outline" className="gap-1">
            <CheckCircle2 className="h-3 w-3 text-green-500" />
            {preview.standalone} independiente{preview.standalone !== 1 ? "s" : ""}
          </Badge>
        )}
        {preview.parents > 0 && (
          <Badge variant="outline" className="gap-1">
            <CheckCircle2 className="h-3 w-3 text-blue-500" />
            {preview.parents} padre{preview.parents !== 1 ? "s" : ""}
          </Badge>
        )}
        {preview.variants > 0 && (
          <Badge variant="outline" className="gap-1">
            <CheckCircle2 className="h-3 w-3 text-purple-500" />
            {preview.variants} variante{preview.variants !== 1 ? "s" : ""}
          </Badge>
        )}
        {preview.warnings > 0 && (
          <Badge variant="outline" className="gap-1 text-yellow-600">
            <AlertTriangle className="h-3 w-3" />
            {preview.warnings} advertencia{preview.warnings !== 1 ? "s" : ""}
          </Badge>
        )}
        {preview.errors > 0 && (
          <Badge variant="destructive" className="gap-1">
            <XCircle className="h-3 w-3" />
            {preview.errors} error{preview.errors !== 1 ? "es" : ""} (se omitirán)
          </Badge>
        )}
      </div>

      {/* Row list */}
      <ScrollArea className="h-64 rounded-md border border-border">
        <div className="p-2 space-y-1">
          {preview.rows.map((row) => (
            <RowPreviewItem key={row.lineNumber} row={row} />
          ))}
        </div>
      </ScrollArea>

      {hasErrors && (
        <p className="text-xs text-muted-foreground">
          Las filas con errores serán omitidas. Las restantes ({validCount}) se importarán igualmente.
        </p>
      )}

      <div className="flex justify-end gap-2 pt-1">
        <Button variant="outline" onClick={onCancel}>Cancelar</Button>
        <Button onClick={onImport} disabled={!canImport}>
          Importar {validCount} fila{validCount !== 1 ? "s" : ""}
          <ChevronRight className="ml-1 h-4 w-4" />
        </Button>
      </div>
    </div>
  )
}

function RowPreviewItem({ row }: { row: ValidatedImportRow }) {
  const hasError   = row.errors.length > 0
  const hasWarning = !hasError && row.warnings.length > 0
  const typeLabel  = row.rowType === "Padre" ? "PADRE" : row.rowType === "Variante" ? "VARIANTE" : "PRODUCTO"
  const typeColor  = row.rowType === "Padre" ? "text-blue-500" : row.rowType === "Variante" ? "text-purple-500" : "text-green-500"

  return (
    <div className={`flex items-start gap-2 px-2 py-1.5 rounded text-xs ${hasError ? "bg-destructive/10" : hasWarning ? "bg-yellow-500/10" : ""}`}>
      {hasError
        ? <XCircle className="h-3.5 w-3.5 text-destructive mt-0.5 shrink-0" />
        : hasWarning
          ? <AlertTriangle className="h-3.5 w-3.5 text-yellow-500 mt-0.5 shrink-0" />
          : <CheckCircle2 className="h-3.5 w-3.5 text-green-500 mt-0.5 shrink-0" />
      }
      <div className="min-w-0 flex-1">
        <span className={`font-medium ${typeColor} mr-1.5`}>[{typeLabel}]</span>
        <span className="text-foreground">{row.name || <em className="text-muted-foreground">sin nombre</em>}</span>
        {row.sku && <span className="text-muted-foreground ml-1.5">SKU: {row.sku}</span>}
        {(row.errors.length > 0 || row.warnings.length > 0) && (
          <div className="mt-0.5 space-y-0.5">
            {row.errors.map((e, i) => (
              <p key={i} className="text-destructive">{e}</p>
            ))}
            {row.warnings.map((w, i) => (
              <p key={i} className="text-yellow-600">{w}</p>
            ))}
          </div>
        )}
      </div>
      <span className="text-muted-foreground shrink-0">L{row.lineNumber}</span>
    </div>
  )
}

// ─── Step: Importing ──────────────────────────────────────────────────────────

function ImportingStep({ progress, label }: { progress: number; label: string }) {
  return (
    <div className="py-8 space-y-4 text-center">
      <Loader2 className="mx-auto h-8 w-8 animate-spin text-primary" />
      <p className="text-sm text-muted-foreground">{label}</p>
      <Progress value={progress} className="h-2" />
      <p className="text-xs text-muted-foreground">{progress}%</p>
    </div>
  )
}

// ─── Step: Result ─────────────────────────────────────────────────────────────

function ResultStep({ result, onClose }: { result: ImportResult; onClose: () => void }) {
  const totalOk  = result.inserted + result.updated
  const totalErr = result.validationErrors.length + result.dbErrors.length

  return (
    <div className="space-y-4">
      <div className="flex flex-wrap gap-2">
        {result.inserted > 0 && (
          <Badge variant="outline" className="gap-1">
            <CheckCircle2 className="h-3 w-3 text-green-500" />
            {result.inserted} nuevo{result.inserted !== 1 ? "s" : ""}
          </Badge>
        )}
        {result.updated > 0 && (
          <Badge variant="outline" className="gap-1">
            <CheckCircle2 className="h-3 w-3 text-blue-500" />
            {result.updated} actualizado{result.updated !== 1 ? "s" : ""}
          </Badge>
        )}
        {result.parents > 0 && (
          <Badge variant="outline" className="gap-1 text-blue-500">
            {result.parents} padre{result.parents !== 1 ? "s" : ""}
          </Badge>
        )}
        {result.variants > 0 && (
          <Badge variant="outline" className="gap-1 text-purple-500">
            {result.variants} variante{result.variants !== 1 ? "s" : ""}
          </Badge>
        )}
        {result.standalone > 0 && (
          <Badge variant="outline" className="gap-1 text-green-500">
            {result.standalone} independiente{result.standalone !== 1 ? "s" : ""}
          </Badge>
        )}
        {totalErr > 0 && (
          <Badge variant="destructive" className="gap-1">
            <XCircle className="h-3 w-3" />
            {totalErr} error{totalErr !== 1 ? "es" : ""}
          </Badge>
        )}
      </div>

      {totalErr > 0 && (
        <ScrollArea className="h-40 rounded-md border border-destructive/30 bg-destructive/5">
          <div className="p-2 space-y-1 text-xs">
            {[...result.validationErrors, ...result.dbErrors].map((e, i) => (
              <p key={i} className="text-destructive">
                {e.lineNumber > 0 ? `L${e.lineNumber} ` : ""}{e.name ? `"${e.name}" — ` : ""}{e.message}
              </p>
            ))}
          </div>
        </ScrollArea>
      )}

      {totalOk === 0 && totalErr === 0 && (
        <p className="text-sm text-muted-foreground text-center py-2">
          No hubo cambios — todos los productos ya existían con los mismos valores.
        </p>
      )}

      <div className="flex justify-end">
        <Button onClick={onClose}>Cerrar</Button>
      </div>
    </div>
  )
}
