"use client"

/**
 * ClientImportDialog
 *
 * 3-step dialog for bulk client imports via CSV upload.
 *
 * Step 1 — Upload
 *   Accept a .csv file (comma or semicolon delimited, UTF-8 with/without BOM).
 *   Show a downloadable template with example rows.
 *
 * Step 2 — Preview & validation
 *   For each CSV row:
 *     - Validate that Nombre is present (required).
 *     - Validate Estado is a known value (activo/inactivo/perdido); defaults to "activo".
 *     - Warn about unrecognised Estado values (non-blocking, defaults applied).
 *   Show a table with per-row status badges (OK / warning / error).
 *   Block confirm if every row has a blocking error.
 *
 * Step 3 — Result
 *   Inserts every valid row via addClient().
 *   Shows a summary: N imported · M errors.
 */

import { useState, useCallback, useRef } from "react"
import { useClients } from "@/hooks/data/use-clients"
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
import type { ClientStatus } from "@/lib/types"
import { cn } from "@/lib/utils"

// ── CSV template ───────────────────────────────────────────────────────────────

const TEMPLATE_CSV = [
  "Nombre;Email;Teléfono;Estado;Categoría",
  "Juan Pérez;juan@ejemplo.com;+54 9 11 1234-5678;activo;Mayorista",
  "María García;maria@ejemplo.com;;inactivo;Minorista",
  "Carlos López;;;activo;",
  "Ana Torres;ana@ejemplo.com;+54 9 351 987-6543;perdido;Premium",
].join("\n")

function downloadTemplate() {
  const blob = new Blob(["﻿" + TEMPLATE_CSV], { type: "text/csv;charset=utf-8;" })
  const url  = URL.createObjectURL(blob)
  const a    = Object.assign(document.createElement("a"), {
    href: url, download: "template_clientes.csv",
  })
  a.click()
  URL.revokeObjectURL(url)
}

// ── Valid statuses ─────────────────────────────────────────────────────────────

const VALID_STATUSES: Record<string, ClientStatus> = {
  activo:   "activo",
  active:   "activo",
  inactivo: "inactivo",
  inactive: "inactivo",
  perdido:  "perdido",
  lost:     "perdido",
}

// ── CSV parser ─────────────────────────────────────────────────────────────────

function parseCSVText(text: string): string[][] {
  const clean = text.replace(/^﻿/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n")
  const lines = clean.split("\n").filter((l) => l.trim() !== "")
  if (lines.length === 0) return []

  const header = lines[0]
  const delim  = (header.split(";").length - 1) >= (header.split(",").length - 1) ? ";" : ","

  return lines.map((line) => {
    const cells: string[] = []
    let current  = ""
    let inQuotes = false
    for (const ch of line) {
      if      (ch === '"')                      { inQuotes = !inQuotes }
      else if (ch === delim && !inQuotes)        { cells.push(current.trim()); current = "" }
      else                                       { current += ch }
    }
    cells.push(current.trim())
    return cells.map((c) => c.replace(/^"|"$/g, "").trim())
  })
}

// ── Row types ──────────────────────────────────────────────────────────────────

type RowStatus = "ok" | "warning" | "error"

interface ParsedRow {
  rowNum:    number
  rawName:   string
  rawEmail:  string
  rawPhone:  string
  rawStatus: string
  rawCategory: string
  resolvedStatus: ClientStatus
  status:    RowStatus
  errors:    string[]
  warnings:  string[]
  // Step 3
  imported?:   boolean
  importError?: string
}

// ── Parse & validate ───────────────────────────────────────────────────────────

function parseAndValidate(cells: string[][]): ParsedRow[] {
  if (cells.length < 2) return []

  const header = cells[0].map((h) =>
    h.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""),
  )

  const idx = {
    name:     header.findIndex((h) => ["nombre", "name"].includes(h)),
    email:    header.findIndex((h) => ["email", "correo", "e-mail"].includes(h)),
    phone:    header.findIndex((h) => ["telefono", "phone", "tel", "celular"].includes(h)),
    status:   header.findIndex((h) => ["estado", "status"].includes(h)),
    category: header.findIndex((h) => ["categoria", "category"].includes(h)),
  }

  if (idx.name < 0) return []

  return cells.slice(1).map((row, i) => {
    const rawName     = row[idx.name]     ?? ""
    const rawEmail    = idx.email    >= 0 ? (row[idx.email]    ?? "") : ""
    const rawPhone    = idx.phone    >= 0 ? (row[idx.phone]    ?? "") : ""
    const rawStatus   = idx.status   >= 0 ? (row[idx.status]   ?? "") : ""
    const rawCategory = idx.category >= 0 ? (row[idx.category] ?? "") : ""

    const errors:   string[] = []
    const warnings: string[] = []

    if (!rawName.trim()) errors.push("Nombre es obligatorio")

    const normStatus = rawStatus.trim().toLowerCase()
    let resolvedStatus: ClientStatus = "activo"
    if (normStatus === "") {
      // No status provided — default silently
    } else if (VALID_STATUSES[normStatus]) {
      resolvedStatus = VALID_STATUSES[normStatus]
    } else {
      warnings.push(`Estado "${rawStatus}" no reconocido — se usará "activo"`)
    }

    const status: RowStatus =
      errors.length > 0 ? "error" : warnings.length > 0 ? "warning" : "ok"

    return {
      rowNum: i + 2,
      rawName, rawEmail, rawPhone, rawStatus, rawCategory,
      resolvedStatus,
      status, errors, warnings,
    }
  })
}

// ── Status badge ───────────────────────────────────────────────────────────────

function StatusBadge({ status }: { status: RowStatus }) {
  if (status === "ok")
    return <span className="inline-flex items-center gap-1 text-emerald-400 text-xs font-medium"><CheckCircle2 className="h-3.5 w-3.5" />OK</span>
  if (status === "warning")
    return <span className="inline-flex items-center gap-1 text-yellow-400 text-xs font-medium"><AlertTriangle className="h-3.5 w-3.5" />Advertencia</span>
  return   <span className="inline-flex items-center gap-1 text-red-400 text-xs font-medium"><XCircle className="h-3.5 w-3.5" />Error</span>
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

// ── Main component ─────────────────────────────────────────────────────────────

interface ClientImportDialogProps {
  open:         boolean
  onOpenChange: (open: boolean) => void
  onSuccess?:   () => void
}

type Step = 1 | 2 | 3

export function ClientImportDialog({
  open,
  onOpenChange,
  onSuccess,
}: ClientImportDialogProps) {
  const { addClient } = useClients()

  const [step,     setStep]     = useState<Step>(1)
  const [rows,     setRows]     = useState<ParsedRow[]>([])
  const [applying, setApplying] = useState(false)
  const [fileName, setFileName] = useState("")

  const fileRef = useRef<HTMLInputElement>(null)

  // ── Stats ──────────────────────────────────────────────────────────────────
  const okCount      = rows.filter((r) => r.status !== "error").length
  const errorCount   = rows.filter((r) => r.status === "error").length
  const warningCount = rows.filter((r) => r.status === "warning").length
  const importedOk   = rows.filter((r) => r.imported === true).length
  const importedErr  = rows.filter((r) => r.imported === false).length

  // ── Reset ──────────────────────────────────────────────────────────────────
  const reset = useCallback(() => {
    setStep(1)
    setRows([])
    setFileName("")
    if (fileRef.current) fileRef.current.value = ""
  }, [])

  // ── File upload ────────────────────────────────────────────────────────────
  const handleFile = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    setFileName(file.name)

    const reader = new FileReader()
    reader.onload = (ev) => {
      const text  = ev.target?.result as string
      const cells = parseCSVText(text)

      if (cells.length < 2) {
        toast.error("El archivo no tiene filas de datos o el formato es incorrecto.")
        return
      }

      const header = cells[0].map((h) =>
        h.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""),
      )
      const hasName = header.some((h) => ["nombre", "name"].includes(h))

      if (!hasName) {
        toast.error('El CSV debe tener al menos la columna "Nombre".')
        return
      }

      const parsed = parseAndValidate(cells)
      setRows(parsed)
      setStep(2)
    }
    reader.readAsText(file, "UTF-8")
  }, [])

  // ── Apply import ───────────────────────────────────────────────────────────
  const handleApply = useCallback(async () => {
    setApplying(true)
    const updated = [...rows]

    for (let i = 0; i < updated.length; i++) {
      const row = updated[i]
      if (row.status === "error") {
        updated[i] = { ...row, imported: false, importError: "Fila omitida por errores de validación" }
        continue
      }
      try {
        await addClient({
          name:         row.rawName.trim(),
          email:        row.rawEmail.trim(),
          phone:        row.rawPhone.trim(),
          status:       row.resolvedStatus,
          category:     row.rawCategory.trim() || undefined,
          lastPurchase: "-",
          totalSpent:   0,
        })
        updated[i] = { ...row, imported: true }
      } catch (err: any) {
        updated[i] = { ...row, imported: false, importError: err?.message ?? "Error desconocido" }
      }
    }

    setRows(updated)
    setApplying(false)
    setStep(3)

    const ok  = updated.filter((r) => r.imported === true).length
    const err = updated.filter((r) => r.imported === false && r.status !== "error").length

    if (err === 0) {
      toast.success(`${ok} cliente${ok !== 1 ? "s" : ""} importado${ok !== 1 ? "s" : ""} correctamente`)
      onSuccess?.()
    } else {
      toast.warning(`${ok} OK · ${err} con error — revisá los detalles`)
    }
  }, [rows, addClient, onSuccess])

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) reset(); onOpenChange(v) }}>
      <DialogContent className="bg-card border-border sm:max-w-[680px] max-h-[90vh] flex flex-col gap-0 p-0">

        {/* Header */}
        <div className="flex items-start justify-between gap-4 px-6 pt-6 pb-4 border-b border-border shrink-0">
          <div className="min-w-0">
            <DialogTitle className="text-base font-semibold text-card-foreground">
              Importar clientes
            </DialogTitle>
            <DialogDescription className="text-sm text-muted-foreground mt-0.5">
              Cargá un CSV con los clientes a importar
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
                htmlFor="csv-client-upload"
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
                  id="csv-client-upload"
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
                <div className="grid grid-cols-2 gap-x-6 gap-y-1.5 text-xs">
                  <div>
                    <span className="font-medium text-foreground">Nombre</span>
                    {" "}<span className="text-muted-foreground">(obligatorio)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Email</span>
                    {" "}<span className="text-muted-foreground">(opcional)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Teléfono</span>
                    {" "}<span className="text-muted-foreground">(opcional)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Estado</span>
                    {" "}<span className="text-muted-foreground">(opcional)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Categoría</span>
                    {" "}<span className="text-muted-foreground">(opcional)</span>
                  </div>
                </div>
              </div>

              {/* Status reference */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Valores válidos para Estado
                </p>
                <div className="flex flex-wrap gap-2 text-xs text-muted-foreground">
                  {["activo", "inactivo", "perdido"].map((s) => (
                    <span key={s} className="px-2 py-0.5 rounded bg-muted font-medium text-foreground">{s}</span>
                  ))}
                </div>
                <p className="text-[11px] text-muted-foreground/60">
                  Si omitís Estado, se asignará "activo" por defecto.
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
                  <span className="font-medium text-foreground">{rows.length}</span> filas · Archivo: {fileName}
                </span>
                <div className="flex items-center gap-2 ml-auto flex-wrap">
                  {(okCount - warningCount) > 0 && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30 text-xs">{okCount - warningCount} OK</Badge>}
                  {warningCount > 0            && <Badge variant="outline" className="text-yellow-400 border-yellow-500/30 text-xs">{warningCount} advertencia{warningCount !== 1 ? "s" : ""}</Badge>}
                  {errorCount > 0              && <Badge variant="outline" className="text-red-400 border-red-500/30 text-xs">{errorCount} error{errorCount !== 1 ? "es" : ""}</Badge>}
                </div>
              </div>

              {/* Table */}
              <ScrollArea className="flex-1 h-[320px]">
                <div className="px-4 py-2">
                  <div className="hidden sm:grid grid-cols-[32px_1fr_140px_100px_80px] gap-2 px-2 py-1.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide border-b border-border/50 sticky top-0 bg-card z-10">
                    <span>#</span>
                    <span>Nombre</span>
                    <span>Email</span>
                    <span>Estado</span>
                    <span>Estado</span>
                  </div>

                  {rows.map((row) => (
                    <div
                      key={row.rowNum}
                      className={cn(
                        "grid sm:grid-cols-[32px_1fr_140px_100px_80px] gap-2 px-2 py-2.5 border-b border-border/40 last:border-0 items-start",
                        row.status === "error"   && "bg-red-500/5",
                        row.status === "warning" && "bg-yellow-500/5",
                      )}
                    >
                      <span className="text-[11px] text-muted-foreground tabular-nums pt-0.5 hidden sm:block">{row.rowNum}</span>

                      <div className="min-w-0 col-span-4 sm:col-span-1">
                        <p className="text-sm font-medium text-foreground truncate">
                          {row.rawName || <span className="italic text-muted-foreground">sin nombre</span>}
                        </p>
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

                      <span className="text-xs text-muted-foreground hidden sm:block pt-0.5 truncate">
                        {row.rawEmail || "—"}
                      </span>

                      <span className="text-xs font-medium text-foreground hidden sm:block pt-0.5 capitalize">
                        {row.resolvedStatus}
                      </span>

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
                    <span className="text-red-400 font-medium">{errorCount} fila{errorCount !== 1 ? "s" : ""} con error</span>
                    {" "}— se omitirán al confirmar.
                    {okCount > 0 && <span> Se importarán las <span className="font-medium text-foreground">{okCount}</span> filas válidas.</span>}
                  </p>
                </div>
              )}
            </div>
          )}

          {/* ── STEP 3: Result ── */}
          {step === 3 && (
            <div className="flex flex-col h-full">
              <div className="flex flex-col items-center justify-center gap-3 px-6 py-6 border-b border-border shrink-0">
                {importedErr === 0 ? (
                  <CheckCircle2 className="h-10 w-10 text-emerald-400" />
                ) : importedOk === 0 ? (
                  <XCircle className="h-10 w-10 text-red-400" />
                ) : (
                  <AlertTriangle className="h-10 w-10 text-yellow-400" />
                )}
                <div className="text-center">
                  <p className="text-base font-semibold text-foreground">
                    {importedErr === 0
                      ? `${importedOk} cliente${importedOk !== 1 ? "s" : ""} importado${importedOk !== 1 ? "s" : ""} correctamente`
                      : importedOk === 0
                      ? "No se pudo importar ningún cliente"
                      : `${importedOk} OK · ${importedErr} con error`}
                  </p>
                  {importedErr > 0 && (
                    <p className="text-sm text-muted-foreground mt-1">
                      Las filas con error no fueron importadas.
                    </p>
                  )}
                </div>
                <div className="flex items-center gap-2">
                  {importedOk  > 0 && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30">{importedOk} importados</Badge>}
                  {importedErr > 0 && <Badge variant="outline" className="text-red-400 border-red-500/30">{importedErr} errores</Badge>}
                </div>
              </div>

              {importedErr > 0 && (
                <ScrollArea className="flex-1 h-[220px]">
                  <div className="px-6 py-3 flex flex-col gap-1.5">
                    <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mb-1">
                      Detalle de errores
                    </p>
                    {rows
                      .filter((r) => r.imported === false && r.importError && r.status !== "error")
                      .map((row) => (
                        <div key={row.rowNum} className="flex items-start gap-2 text-xs">
                          <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">Fila {row.rowNum}</span>
                          <span className="font-medium text-foreground shrink-0">{row.rawName}</span>
                          <span className="text-red-400">{row.importError}</span>
                        </div>
                      ))}
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
                  <><Loader2 className="h-3.5 w-3.5 animate-spin" />Importando…</>
                ) : (
                  <>Importar {okCount} cliente{okCount !== 1 ? "s" : ""}</>
                )}
              </Button>
            )}

            {step === 3 && importedErr > 0 && (
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
