"use client"

/**
 * StockImportAdjustmentDialog
 *
 * 3-step dialog for bulk stock adjustments via CSV upload.
 *
 * Step 1 — Upload
 *   Accept a .csv file (comma or semicolon delimited, UTF-8 with/without BOM).
 *   Show a downloadable template and the list of supported type values.
 *
 * Step 2 — Preview & validation
 *   For each CSV row:
 *     - Resolve the product by name (exact → partial → not found).
 *     - Validate the type column (maps Spanish labels to DB types).
 *     - Validate the quantity (numeric, > 0 for non-physical_count).
 *     - Check for variant_only / untracked products (blocked).
 *   Show a table with per-row status badges (OK / warning / error).
 *   Block confirm if there are any blocking errors.
 *   The user can proceed even with warnings.
 *
 * Step 3 — Result
 *   Applies every valid row sequentially via rpc_stock_adjustment.
 *   Shows a summary: N OK · M errors.
 *   Errors from the server (e.g. stock insuficiente) are shown per-row.
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
import type { Product, MovementType } from "@/lib/types"
import { cn } from "@/lib/utils"

// ── CSV template ───────────────────────────────────────────────────────────────

const TEMPLATE_CSV = [
  "Nombre;Tipo;Cantidad;Motivo",
  "Zapatillas Nike 42;Conteo físico;25;Inventario mensual",
  "Remera básica XL;Ajuste entrada;10;Reposición de proveedor",
  "Pantalón jean 32;Pérdida;3;Robo registrado",
  "Camiseta polo M;Ajuste salida;5;Devolución a depósito",
].join("\n")

function downloadTemplate() {
  const blob = new Blob(["﻿" + TEMPLATE_CSV], { type: "text/csv;charset=utf-8;" })
  const url  = URL.createObjectURL(blob)
  const a    = Object.assign(document.createElement("a"), {
    href: url, download: "template_ajuste_stock.csv",
  })
  a.click()
  URL.revokeObjectURL(url)
}

// ── Type aliases (Spanish → internal uiKey) ────────────────────────────────────

const TYPE_ALIASES: Record<string, string> = {
  // adjustment_in
  "ajuste entrada":    "adjustment_in",
  "ajuste de entrada": "adjustment_in",
  "entrada":           "adjustment_in",
  "ingreso":           "adjustment_in",
  // adjustment_out
  "ajuste salida":     "adjustment_out",
  "ajuste de salida":  "adjustment_out",
  "salida":            "adjustment_out",
  "egreso":            "adjustment_out",
  // physical_count
  "conteo fisico":     "physical_count",
  "conteo físico":     "physical_count",
  "conteo":            "physical_count",
  "inventario":        "physical_count",
  // loss
  "perdida":           "loss",
  "pérdida":           "loss",
  "robo":              "loss",
  "extravío":          "loss",
  "extravio":          "loss",
  // damage
  "daño":              "damage",
  "dano":              "damage",
  "merma":             "damage",
  "deterioro":         "damage",
  // expiry
  "vencimiento":       "expiry",
  "vencido":           "expiry",
  // transfer_in
  "transferencia entrada": "transfer_in",
  "transfer entrada":      "transfer_in",
  "recepcion":             "transfer_in",
  "recepción":             "transfer_in",
  // transfer_out
  "transferencia salida":  "transfer_out",
  "transfer salida":       "transfer_out",
  "envio":                 "transfer_out",
  "envío":                 "transfer_out",
}

const UI_KEY_TO_DB: Record<string, { type: MovementType; sign: 1 | -1 | 0 }> = {
  adjustment_in:  { type: "adjustment",    sign:  1 },
  adjustment_out: { type: "adjustment",    sign: -1 },
  physical_count: { type: "physical_count", sign:  0 },
  loss:           { type: "loss",           sign: -1 },
  damage:         { type: "damage",         sign: -1 },
  expiry:         { type: "expiry",         sign: -1 },
  transfer_in:    { type: "transfer_in",    sign:  1 },
  transfer_out:   { type: "transfer_out",   sign: -1 },
}

// Friendly label for display
const UI_KEY_LABEL: Record<string, string> = {
  adjustment_in:  "Ajuste entrada",
  adjustment_out: "Ajuste salida",
  physical_count: "Conteo físico",
  loss:           "Pérdida / Robo",
  damage:         "Daño / Merma",
  expiry:         "Vencimiento",
  transfer_in:    "Transferencia ent.",
  transfer_out:   "Transferencia sal.",
}

function resolveType(raw: string): string | null {
  const key = raw.trim().toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, "")
  // Try normalised version too
  for (const [alias, uiKey] of Object.entries(TYPE_ALIASES)) {
    const normAlias = alias.normalize("NFD").replace(/[̀-ͯ]/g, "")
    if (key === normAlias) return uiKey
  }
  // Direct match against uiKey (e.g. "adjustment_in")
  if (key in UI_KEY_TO_DB) return key
  return null
}

// ── CSV parser ─────────────────────────────────────────────────────────────────

function parseCSVText(text: string): string[][] {
  const clean = text.replace(/^﻿/, "").replace(/\r\n/g, "\n").replace(/\r/g, "\n")
  const lines = clean.split("\n").filter((l) => l.trim() !== "")
  if (lines.length === 0) return []

  // Auto-detect delimiter: count `;` vs `,` in header row
  const header  = lines[0]
  const delim   = (header.split(";").length - 1) >= (header.split(",").length - 1) ? ";" : ","

  return lines.map((line) => {
    const cells: string[] = []
    let current  = ""
    let inQuotes = false
    for (const ch of line) {
      if      (ch === '"')    { inQuotes = !inQuotes }
      else if (ch === delim && !inQuotes) { cells.push(current.trim()); current = "" }
      else    { current += ch }
    }
    cells.push(current.trim())
    return cells.map((c) => c.replace(/^"|"$/g, "").trim())
  })
}

// ── Row types ──────────────────────────────────────────────────────────────────

type RowStatus = "ok" | "warning" | "error"

interface ParsedImportRow {
  /** Original CSV row index (1-based, after header) */
  rowNum:      number
  /** Raw CSV values */
  rawName:     string
  rawType:     string
  rawQuantity: string
  rawMotivo:   string
  /** Resolution results */
  product:     Product | null
  resolvedName: string | null   // actual product name found (if different from rawName)
  uiKey:       string           // resolved movement uiKey
  quantity:    number           // parsed quantity
  // Validation
  status:      RowStatus
  errors:      string[]         // blocking errors
  warnings:    string[]         // non-blocking warnings
  // Applied result (step 3)
  applied?:    boolean
  applyError?: string
}

// ── Product resolution by name ─────────────────────────────────────────────────

function resolveProductByName(
  name: string,
  candidates: Product[],
): { product: Product | null; resolvedName: string | null; status: "exact" | "partial" | "ambiguous" | "not_found" } {
  const q = name.trim().toLowerCase()
  if (!q) return { product: null, resolvedName: null, status: "not_found" }

  // Exact match (case-insensitive)
  const exact = candidates.filter((p) => p.name.toLowerCase() === q)
  if (exact.length === 1) return { product: exact[0], resolvedName: exact[0].name, status: "exact" }
  if (exact.length > 1)   return { product: null, resolvedName: null, status: "ambiguous" }

  // Partial match: product name contains query OR query contains product name
  const partial = candidates.filter(
    (p) => p.name.toLowerCase().includes(q) || q.includes(p.name.toLowerCase()),
  )
  if (partial.length === 1) return { product: partial[0], resolvedName: partial[0].name, status: "partial" }
  if (partial.length > 1)   return { product: null, resolvedName: null, status: "ambiguous" }

  return { product: null, resolvedName: null, status: "not_found" }
}

// ── Parse & validate CSV rows ──────────────────────────────────────────────────

function parseAndValidate(cells: string[][], adjustableProducts: Product[]): ParsedImportRow[] {
  if (cells.length < 2) return []

  // Normalize header keys
  const header  = cells[0].map((h) => h.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""))
  const colIdx  = {
    name:     header.findIndex((h) => h === "nombre" || h === "producto" || h === "name"),
    type:     header.findIndex((h) => h === "tipo"   || h === "type"     || h === "movimiento"),
    quantity: header.findIndex((h) => h === "cantidad" || h === "qty"    || h === "quantity"),
    motivo:   header.findIndex((h) => h === "motivo" || h === "razon"    || h === "razon" || h === "reason" || h === "nota"),
  }

  if (colIdx.name < 0 || colIdx.quantity < 0) return []

  return cells.slice(1).map((row, i) => {
    const rawName     = row[colIdx.name]     ?? ""
    const rawType     = colIdx.type >= 0 ? (row[colIdx.type] ?? "") : ""
    const rawQuantity = row[colIdx.quantity] ?? ""
    const rawMotivo   = colIdx.motivo >= 0  ? (row[colIdx.motivo] ?? "") : ""

    const errors:   string[] = []
    const warnings: string[] = []

    // Resolve product
    const resolution   = resolveProductByName(rawName, adjustableProducts)
    const product      = resolution.product
    const resolvedName = resolution.resolvedName

    if      (resolution.status === "not_found")  errors.push(`Producto "${rawName}" no encontrado`)
    else if (resolution.status === "ambiguous")   errors.push(`El nombre "${rawName}" coincide con múltiples productos — usá el nombre exacto`)
    else if (resolution.status === "partial")     warnings.push(`Coincidencia parcial → asignado a "${resolvedName}"`)

    // Resolve type (default: adjustment_in)
    const uiKey = rawType.trim() === "" ? "adjustment_in" : (resolveType(rawType) ?? "")
    if (rawType.trim() !== "" && !uiKey) {
      errors.push(`Tipo "${rawType}" no reconocido`)
    }
    if (rawType.trim() === "") {
      warnings.push('Tipo no especificado — se usará "Ajuste entrada" por defecto')
    }

    // Resolve quantity
    const quantity = parseFloat(rawQuantity)
    if (rawQuantity.trim() === "" || isNaN(quantity)) {
      errors.push("Cantidad inválida")
    } else if (quantity < 0) {
      errors.push("La cantidad no puede ser negativa")
    } else if (uiKey !== "physical_count" && quantity === 0) {
      errors.push("La cantidad debe ser mayor a cero para este tipo de movimiento")
    }

    const status: RowStatus = errors.length > 0 ? "error" : warnings.length > 0 ? "warning" : "ok"

    return {
      rowNum:      i + 2,
      rawName, rawType, rawQuantity, rawMotivo,
      product, resolvedName,
      uiKey:    uiKey || "adjustment_in",
      quantity: isNaN(quantity) ? 0 : quantity,
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
  const appliedOk    = rows.filter((r) => r.applied === true).length
  const appliedErr   = rows.filter((r) => r.applied === false).length

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
        p_reason:     row.rawMotivo.trim() || null,
      }

      if (info.sign === 0) {
        // physical_count: send absolute target quantity (server computes delta with lock)
        params.p_target_quantity = row.quantity
      } else {
        params.p_quantity_delta = row.quantity * info.sign
      }

      const { error } = await supabase.rpc("rpc_stock_adjustment", params)
      if (error) {
        updated[i] = { ...row, applied: false, applyError: error.message }
      } else {
        updated[i] = { ...row, applied: true }
      }
    }

    setRows(updated)
    setApplying(false)
    setStep(3)
    await refreshData()

    const ok  = updated.filter((r) => r.applied === true).length
    const err = updated.filter((r) => r.applied === false && r.status !== "error").length

    if (err === 0) {
      toast.success(`${ok} ajuste${ok !== 1 ? "s" : ""} registrado${ok !== 1 ? "s" : ""} correctamente`)
      onSuccess?.()
    } else {
      toast.warning(`${ok} OK · ${err} con error — revisá los detalles`)
    }
  }, [rows, supabase, refreshData, onSuccess])

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
                  <div><span className="font-medium text-foreground">Cantidad</span> <span className="text-muted-foreground">(obligatorio)</span></div>
                  <div><span className="font-medium text-foreground">Tipo</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Motivo</span> <span className="text-muted-foreground">(opcional)</span></div>
                </div>
              </div>

              {/* Type reference */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Valores válidos para la columna Tipo
                </p>
                <div className="grid grid-cols-2 gap-x-6 gap-y-1 text-xs text-muted-foreground">
                  {[
                    ["Ajuste entrada", "Ajuste salida"],
                    ["Conteo físico", "Pérdida / Robo"],
                    ["Daño / Merma", "Vencimiento"],
                    ["Transferencia entrada", "Transferencia salida"],
                  ].map(([a, b], i) => (
                    <div key={i}>{a}</div>
                  )).concat(
                    [["Ajuste entrada", "Ajuste salida"],
                    ["Conteo físico", "Pérdida / Robo"],
                    ["Daño / Merma", "Vencimiento"],
                    ["Transferencia entrada", "Transferencia salida"]].map(([a, b], i) => (
                      <div key={`b${i}`}>{b}</div>
                    ))
                  )}
                </div>
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
                  <span className="font-medium text-foreground">{rows.length}</span> filas · Archivo: {fileName}
                </span>
                <div className="flex items-center gap-2 ml-auto flex-wrap">
                  {okCount > 0      && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30 text-xs">{okCount - warningCount} OK</Badge>}
                  {warningCount > 0 && <Badge variant="outline" className="text-yellow-400 border-yellow-500/30 text-xs">{warningCount} advertencia{warningCount !== 1 ? "s" : ""}</Badge>}
                  {errorCount > 0   && <Badge variant="outline" className="text-red-400 border-red-500/30 text-xs">{errorCount} error{errorCount !== 1 ? "es" : ""}</Badge>}
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

                      {/* Quantity */}
                      <span className="text-xs tabular-nums font-medium text-foreground hidden sm:block pt-0.5">
                        {row.rawQuantity}
                      </span>

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
                    <span className="text-red-400 font-medium">{errorCount} fila{errorCount !== 1 ? "s" : ""} con error</span>
                    {" "}— se omitirán al confirmar.
                    {okCount > 0 && <span> Se aplicarán las <span className="font-medium text-foreground">{okCount}</span> filas válidas.</span>}
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
                {appliedErr === 0 ? (
                  <CheckCircle2 className="h-10 w-10 text-emerald-400" />
                ) : appliedOk === 0 ? (
                  <XCircle className="h-10 w-10 text-red-400" />
                ) : (
                  <AlertTriangle className="h-10 w-10 text-yellow-400" />
                )}
                <div className="text-center">
                  <p className="text-base font-semibold text-foreground">
                    {appliedErr === 0
                      ? `${appliedOk} ajuste${appliedOk !== 1 ? "s" : ""} registrado${appliedOk !== 1 ? "s" : ""} correctamente`
                      : appliedOk === 0
                      ? "No se pudo aplicar ningún ajuste"
                      : `${appliedOk} OK · ${appliedErr} con error`}
                  </p>
                  {appliedErr > 0 && (
                    <p className="text-sm text-muted-foreground mt-1">
                      Las filas con error no modificaron el stock.
                    </p>
                  )}
                </div>
                <div className="flex items-center gap-2">
                  {appliedOk  > 0 && <Badge variant="outline" className="text-emerald-400 border-emerald-500/30">{appliedOk} aplicados</Badge>}
                  {appliedErr > 0 && <Badge variant="outline" className="text-red-400 border-red-500/30">{appliedErr} errores</Badge>}
                </div>
              </div>

              {/* Row results */}
              {appliedErr > 0 && (
                <ScrollArea className="flex-1 h-[220px]">
                  <div className="px-6 py-3 flex flex-col gap-1.5">
                    <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mb-1">
                      Detalle de errores
                    </p>
                    {rows
                      .filter((r) => r.applied === false && r.applyError && r.status !== "error")
                      .map((row) => (
                        <div key={row.rowNum} className="flex items-start gap-2 text-xs">
                          <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">Fila {row.rowNum}</span>
                          <span className="font-medium text-foreground shrink-0">{row.resolvedName ?? row.rawName}</span>
                          <span className="text-red-400">{row.applyError}</span>
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
                  <><Loader2 className="h-3.5 w-3.5 animate-spin" />Aplicando…</>
                ) : (
                  <>Aplicar {okCount} ajuste{okCount !== 1 ? "s" : ""}</>
                )}
              </Button>
            )}

            {step === 3 && appliedErr > 0 && (
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
