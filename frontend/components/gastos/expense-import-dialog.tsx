"use client"

/**
 * ExpenseImportDialog — importador-gastos-transaccional.
 *
 * 3-step dialog for bulk expense imports via CSV upload, ahora respaldado
 * por un LOTE TRANSACCIONAL de servidor (`rpc_import_expenses`, D1 del
 * design): todo el archivo se aplica o no se aplica nada — nunca "importar
 * las que se pueda".
 *
 * Step 1 — Archivo
 *   Template de SIETE columnas (las tres nuevas son opcionales,
 *   retrocompatible con el de cuatro). Valores por defecto del lote: forma
 *   de pago, sucursal, centro de costo y cuenta bancaria de respaldo.
 *
 * Step 2 — Revisión = VEREDICTO DEL SERVIDOR (D9)
 *   Al entrar, dispara automáticamente una SIMULACIÓN (`dryRun: true`) por la
 *   MISMA RPC — el servidor resuelve nombres, corre cada alta y deshace todo.
 *   La tabla muestra el estado combinado (validación de cliente + servidor):
 *   ok / aviso / error. La confirmación se deshabilita mientras exista UNA
 *   sola fila con error — el lote es todo o nada, "importar las que se
 *   pueda" ya no existe.
 *
 * Step 3 — Resultado
 *   Reporta el lote real (`dryRun: false`, misma clave de idempotencia):
 *   N importados, archivo, aviso de repetición si el lote ya se había
 *   aplicado.
 */

import { useState, useCallback, useRef, useEffect } from "react"
import { useImportExpenses } from "@/hooks/data/use-expenses-query"
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
import { EXPENSE_CATEGORIES, EXPENSE_IMPORT_MAX_ROWS } from "@/lib/constants"
import { amountAmbiguityWarning, parseAmount, parseDate } from "@/lib/excel"
import { argentinaToday } from "@/lib/date-range"
import { cn } from "@/lib/utils"
import { hashFileSHA256 } from "@/lib/bank-statement-parser"
import { PaymentMethodSelect, BankAccountDestinationSelect } from "@/components/payment-methods/PaymentMethodSelect"
import { BranchSelect } from "@/components/branches/BranchSelect"
import { CostCenterSelect } from "@/components/cost-centers/CostCenterSelect"
import type { ExpenseImportResult } from "@/lib/types"

// ── CSV template (7 columnas — las 3 últimas OPCIONALES, D4) ───────────────

const TEMPLATE_CSV = [
  "Descripción;Categoría;Monto;Fecha;Forma de pago;Sucursal;Centro de costo",
  "Alquiler local comercial;Alquiler;85000;2026-05-01;Transferencia bancaria;;",
  "Servicio de internet;Servicios;4500;01/05/2026;;;",
  "Publicidad en redes;Marketing;12000;;Efectivo;;",
  "Salarios del mes;Personal;250000;2026-05-31;;;",
].join("\n")

function downloadTemplate() {
  const blob = new Blob(["﻿" + TEMPLATE_CSV], { type: "text/csv;charset=utf-8;" })
  const url  = URL.createObjectURL(blob)
  const a    = Object.assign(document.createElement("a"), {
    href: url, download: "template_gastos.csv",
  })
  a.click()
  URL.revokeObjectURL(url)
}

// ── Valid categories (set for O(1) lookup) ─────────────────────────────────────

const VALID_CATEGORIES = new Set<string>(EXPENSE_CATEGORIES)

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

/** Estado combinado (validación de CLIENTE + veredicto del SERVIDOR, D9). */
type RowStatus = "ok" | "warning" | "error"

interface ParsedRow {
  rowNum:          number
  rawDescription:  string
  rawCategory:     string
  rawAmount:       string
  rawDate:         string
  // Tres columnas nuevas (D4) — RAW: la resolución por nombre la hace el
  // SERVIDOR (rpc_import_expenses), nunca el cliente. Enviar el nombre tal
  // cual, sin normalizar acá, sería una segunda definición de la resolución.
  rawPaymentMethod: string
  rawBranch:        string
  rawCostCenter:    string
  resolvedCategory: string
  resolvedAmount:  number
  resolvedDate:    string
  /** Estado de la validación de CLIENTE únicamente (obligatorio/monto/fecha). */
  status:          RowStatus
  errors:          string[]
  warnings:        string[]
}

/** Error o aviso del servidor para una fila, indexado por `rowNum`. */
interface ServerVerdict {
  error?:  { code: string; message: string }
  notice?: { code: string; message: string }
}

// ── Parse & validate ───────────────────────────────────────────────────────────

// Exportada para test unitario (app-timezone-argentina, task 2.4) — cubre la
// comparación "es hoy" de la línea 166 sin necesidad de montar el diálogo
// completo.
export function parseAndValidate(cells: string[][]): ParsedRow[] {
  if (cells.length < 2) return []

  const header = cells[0].map((h) =>
    h.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""),
  )

  const idx = {
    description: header.findIndex((h) =>
      ["descripcion", "description", "descripción", "detalle", "concepto"].includes(h)),
    category: header.findIndex((h) =>
      ["categoria", "category", "categoría"].includes(h)),
    amount: header.findIndex((h) =>
      ["monto", "amount", "importe", "total", "valor"].includes(h)),
    date: header.findIndex((h) =>
      ["fecha", "date"].includes(h)),
    // importador-gastos-transaccional (D4): tres columnas nuevas, siempre
    // OPCIONALES — un CSV de 4 columnas (compatibilidad hacia atrás,
    // requirement explícito) simplemente no las encuentra (idx = -1).
    paymentMethod: header.findIndex((h) =>
      ["forma de pago", "payment method", "paymentmethod", "método de pago", "metodo de pago"].includes(h)),
    branch: header.findIndex((h) =>
      ["sucursal", "branch"].includes(h)),
    costCenter: header.findIndex((h) =>
      ["centro de costo", "cost center", "costcenter"].includes(h)),
  }

  if (idx.description < 0 || idx.amount < 0) return []

  return cells.slice(1).map((row, i) => {
    const rawDescription = row[idx.description]  ?? ""
    const rawCategory    = idx.category >= 0 ? (row[idx.category]  ?? "") : ""
    const rawAmount      = idx.amount   >= 0 ? (row[idx.amount]    ?? "") : ""
    const rawDate        = idx.date     >= 0 ? (row[idx.date]      ?? "") : ""
    const rawPaymentMethod = idx.paymentMethod >= 0 ? (row[idx.paymentMethod] ?? "") : ""
    const rawBranch        = idx.branch        >= 0 ? (row[idx.branch]        ?? "") : ""
    const rawCostCenter    = idx.costCenter     >= 0 ? (row[idx.costCenter]     ?? "") : ""

    const errors:   string[] = []
    const warnings: string[] = []

    // Validate description
    if (!rawDescription.trim()) errors.push("Descripción es obligatoria")

    // Validate amount
    const resolvedAmount = parseAmount(rawAmount)
    if (rawAmount.trim() === "" || isNaN(resolvedAmount)) {
      errors.push("Monto inválido — debe ser un número")
    } else if (resolvedAmount <= 0) {
      errors.push("El monto debe ser mayor a cero")
    } else {
      const ambiguity = amountAmbiguityWarning("Monto", rawAmount, resolvedAmount)
      if (ambiguity) warnings.push(ambiguity)
    }

    // Validate category
    let resolvedCategory = "Otros"
    if (rawCategory.trim() === "") {
      warnings.push('Categoría no especificada — se usará "Otros"')
    } else if (VALID_CATEGORIES.has(rawCategory.trim())) {
      resolvedCategory = rawCategory.trim()
    } else {
      warnings.push(`Categoría "${rawCategory}" no reconocida — se usará "Otros"`)
    }

    // Parse date (defaults to today if empty/invalid)
    const resolvedDate = parseDate(rawDate)
    if (rawDate.trim() !== "" && resolvedDate === argentinaToday()) {
      // parseDate fell back to today — likely unrecognised format
      const isoPattern = /^\d{4}-\d{2}-\d{2}$/
      const slashPattern = /^\d{1,2}\/\d{1,2}\/\d{4}$/
      if (!isoPattern.test(rawDate.trim()) && !slashPattern.test(rawDate.trim())) {
        warnings.push(`Fecha "${rawDate}" no reconocida — se usará la fecha de hoy`)
      }
    }

    const status: RowStatus =
      errors.length > 0 ? "error" : warnings.length > 0 ? "warning" : "ok"

    return {
      rowNum: i + 2,
      rawDescription, rawCategory, rawAmount, rawDate,
      rawPaymentMethod, rawBranch, rawCostCenter,
      resolvedCategory,
      resolvedAmount: isNaN(resolvedAmount) ? 0 : resolvedAmount,
      resolvedDate,
      status, errors, warnings,
    }
  })
}

// ── Currency format (compact, no external dep) ─────────────────────────────────

function formatAmount(n: number): string {
  return n.toLocaleString("es-AR", { minimumFractionDigits: 0, maximumFractionDigits: 2 })
}

// ── Status badge — TOKENS SEMÁNTICOS (task 8.8, gate token-contrast-aa) ────────

function StatusBadge({ status, loading }: { status: RowStatus; loading?: boolean }) {
  if (loading)
    return <span className="inline-flex items-center gap-1 text-muted-foreground text-xs font-medium"><Loader2 className="h-3.5 w-3.5 animate-spin" />Validando…</span>
  if (status === "ok")
    return <span className="inline-flex items-center gap-1 text-success text-xs font-medium"><CheckCircle2 className="h-3.5 w-3.5" />OK</span>
  if (status === "warning")
    return <span className="inline-flex items-center gap-1 text-warning text-xs font-medium"><AlertTriangle className="h-3.5 w-3.5" />Aviso</span>
  return   <span className="inline-flex items-center gap-1 text-destructive text-xs font-medium"><XCircle className="h-3.5 w-3.5" />Error</span>
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

interface ExpenseImportDialogProps {
  open:         boolean
  onOpenChange: (open: boolean) => void
  onSuccess?:   () => void
}

type Step = 1 | 2 | 3

export function ExpenseImportDialog({
  open,
  onOpenChange,
  onSuccess,
}: ExpenseImportDialogProps) {
  // El lote es UNA sola request de servidor (rpc_import_expenses, D1). La
  // MISMA mutación sirve para la simulación (dryRun: true, paso 2) y para
  // la confirmación real (dryRun: false, paso 3) — la vista previa no es un
  // validador aparte (D9).
  const { importMutation, invalidateLedgers } = useImportExpenses()

  const [step,     setStep]     = useState<Step>(1)
  const [rows,     setRows]     = useState<ParsedRow[]>([])
  const [applying, setApplying] = useState(false)
  const [fileName, setFileName] = useState("")
  const [fileHash, setFileHash] = useState("")

  // Clave de idempotencia: UNA por archivo elegido (task 7.4), no por click —
  // así la simulación y la confirmación (y un reintento del mismo archivo)
  // comparten clave y un reintento real es un replay, no un segundo lote.
  const [idempotencyKey, setIdempotencyKey] = useState("")

  // ── Valores por defecto del lote (D10) — los cuatro, todos opcionales ──────
  const [defaultPaymentMethodId, setDefaultPaymentMethodId] = useState<string | null>(null)
  const [defaultBranchId,        setDefaultBranchId]        = useState<string | null>(null)
  const [defaultCostCenterId,    setDefaultCostCenterId]     = useState<string | null>(null)
  const [fallbackBankAccountId,  setFallbackBankAccountId]   = useState<string | null>(null)

  // ── Veredicto del servidor (paso 2, D9) ────────────────────────────────────
  const [serverVerdicts, setServerVerdicts] = useState<Record<number, ServerVerdict>>({})
  const [serverLoading,  setServerLoading]  = useState(false)
  const [serverResult,   setServerResult]   = useState<ExpenseImportResult | null>(null)
  const dryRunTriggeredRef = useRef(false)

  const fileRef = useRef<HTMLInputElement>(null)

  // ── Fila → payload de la RPC (comparte forma entre simulación y real) ─────
  const toApiRows = useCallback(
    (source: ParsedRow[]) =>
      source
        .filter((r) => r.status !== "error")
        .map((r) => ({
          rowNo: r.rowNum,
          description: r.rawDescription.trim(),
          category: r.resolvedCategory,
          amount: r.resolvedAmount,
          date: r.resolvedDate,
          paymentMethodName: r.rawPaymentMethod.trim() || null,
          branchName: r.rawBranch.trim() || null,
          costCenterName: r.rawCostCenter.trim() || null,
        })),
    [],
  )

  // ── Estado combinado por fila: cliente + servidor (D9) ─────────────────────
  const finalStatusFor = useCallback(
    (row: ParsedRow): RowStatus => {
      if (row.status === "error") return "error"
      const verdict = serverVerdicts[row.rowNum]
      if (verdict?.error) return "error"
      if (verdict?.notice || row.status === "warning") return "warning"
      return "ok"
    },
    [serverVerdicts],
  )
  const finalMessagesFor = useCallback(
    (row: ParsedRow): { errors: string[]; warnings: string[] } => {
      const verdict = serverVerdicts[row.rowNum]
      return {
        errors: [...row.errors, ...(verdict?.error ? [verdict.error.message] : [])],
        warnings: [...row.warnings, ...(verdict?.notice ? [verdict.notice.message] : [])],
      }
    },
    [serverVerdicts],
  )

  // ── Stats (sobre el estado COMBINADO) ──────────────────────────────────────
  const finalStatuses = rows.map(finalStatusFor)
  const errorCount    = finalStatuses.filter((s) => s === "error").length
  const warningCount  = finalStatuses.filter((s) => s === "warning").length
  const okCount       = rows.length - errorCount

  // ── Reset ──────────────────────────────────────────────────────────────────
  const reset = useCallback(() => {
    setStep(1)
    setRows([])
    setFileName("")
    setFileHash("")
    setIdempotencyKey("")
    setDefaultPaymentMethodId(null)
    setDefaultBranchId(null)
    setDefaultCostCenterId(null)
    setFallbackBankAccountId(null)
    setServerVerdicts({})
    setServerLoading(false)
    setServerResult(null)
    dryRunTriggeredRef.current = false
    if (fileRef.current) fileRef.current.value = ""
  }, [])

  // ── File upload ────────────────────────────────────────────────────────────
  const handleFile = useCallback((e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    if (!file) return
    setFileName(file.name)

    const reader = new FileReader()
    reader.onload = async (ev) => {
      const text  = ev.target?.result as string
      const cells = parseCSVText(text)

      if (cells.length < 2) {
        toast.error("El archivo no tiene filas de datos o el formato es incorrecto.")
        return
      }

      const header = cells[0].map((h) =>
        h.toLowerCase().normalize("NFD").replace(/[̀-ͯ]/g, ""),
      )
      const hasDesc   = header.some((h) =>
        ["descripcion", "description", "descripción", "detalle", "concepto"].includes(h))
      const hasAmount = header.some((h) =>
        ["monto", "amount", "importe", "total", "valor"].includes(h))

      if (!hasDesc || !hasAmount) {
        toast.error('El CSV debe tener al menos las columnas "Descripción" y "Monto".')
        return
      }

      const parsed = parseAndValidate(cells)

      // F2 (revisión adversarial post-apply): el mismo tope que aplica
      // `rpc_import_expenses` (P0427), pero acá ANTES de avanzar al paso 2 —
      // sin esto, un archivo de más de 500 filas paga el viaje entero a la
      // RPC sólo para recibir un 422 que el usuario ni ve (la simulación
      // fallada deja `serverVerdicts` vacío y el botón de confirmar queda
      // habilitado, D8 del design).
      if (parsed.length > EXPENSE_IMPORT_MAX_ROWS) {
        toast.error(
          `Máximo ${EXPENSE_IMPORT_MAX_ROWS} filas por lote (recibidas ${parsed.length}) — partí el archivo en lotes más chicos.`,
        )
        return
      }

      setRows(parsed)
      // F1 (revisión adversarial post-apply): el veredicto del archivo
      // ANTERIOR queda indexado por número de fila (`serverVerdicts[rowNum]`)
      // — sin limpiarlo acá, se pinta sobre las filas del archivo NUEVO
      // hasta que la simulación nueva resuelve (y para siempre si esa
      // simulación falla, ver el `.catch` de abajo).
      setServerVerdicts({})
      setServerResult(null)
      dryRunTriggeredRef.current = false
      // hashFileSHA256 (lib/bank-statement-parser.ts) — NO se reescribe un
      // segundo hasher (task 8.4).
      const hash = await hashFileSHA256(file)
      setFileHash(hash)
      setIdempotencyKey(crypto.randomUUID())
      setStep(2)
    }
    reader.readAsText(file, "UTF-8")
  }, [])

  // ── Simulación automática al entrar al paso 2 (D9) ─────────────────────────
  useEffect(() => {
    if (step !== 2 || dryRunTriggeredRef.current) return
    if (rows.length === 0 || !fileHash || !idempotencyKey) return
    dryRunTriggeredRef.current = true

    const rowsToSend = toApiRows(rows)
    if (rowsToSend.length === 0) {
      // Ninguna fila pasó la validación de cliente — nada que preguntarle al
      // servidor; el botón queda deshabilitado igual por errorCount > 0.
      return
    }

    setServerLoading(true)
    importMutation
      .mutateAsync({
        fileName, fileHash, dryRun: true,
        defaultPaymentMethodId, defaultBranchId, defaultCostCenterId, fallbackBankAccountId,
        idempotencyKey,
        rows: rowsToSend,
      })
      .then((result) => {
        setServerResult(result)
        const verdicts: Record<number, ServerVerdict> = {}
        for (const e of result.errors) {
          verdicts[e.row] = { ...verdicts[e.row], error: { code: e.code, message: e.message } }
        }
        for (const n of result.notices) {
          verdicts[n.row] = { ...verdicts[n.row], notice: { code: n.code, message: n.message } }
        }
        setServerVerdicts(verdicts)
      })
      .catch((err: unknown) => {
        // F1: un fallo de red no debe dejar veredictos huérfanos de un
        // intento anterior (no hay reintento automático — quedarían para
        // siempre pintados sobre las filas actuales).
        setServerVerdicts({})
        setServerResult(null)
        const message = err instanceof Error ? err.message : "Error desconocido"
        toast.error(`No se pudo validar el archivo contra el servidor: ${message}`)
      })
      .finally(() => setServerLoading(false))
    // importMutation es estable entre renders (useMutation de TanStack Query);
    // sólo re-disparar cuando cambia el archivo (rows/fileHash/idempotencyKey).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step, rows, fileHash, idempotencyKey])

  // ── Confirmar el lote (real, dryRun: false, MISMA clave — D2/D9) ──────────
  const handleApply = useCallback(async () => {
    setApplying(true)
    try {
      const rowsToSend = toApiRows(rows)
      const result = await importMutation.mutateAsync({
        fileName, fileHash, dryRun: false,
        defaultPaymentMethodId, defaultBranchId, defaultCostCenterId, fallbackBankAccountId,
        idempotencyKey,
        rows: rowsToSend,
      })
      setServerResult(result)

      if (result.committed) {
        // Una sola invalidación por lote — nunca por fila (requirement de
        // expense-import: gastos y ledger bancario incluidos).
        invalidateLedgers()
        setStep(3)
        if (result.replayed) {
          toast.info("Este archivo ya se había importado — no se creó un lote nuevo.")
        } else {
          toast.success(`${result.imported} gasto${result.imported !== 1 ? "s" : ""} importado${result.imported !== 1 ? "s" : ""} correctamente`)
          onSuccess?.()
        }
      } else {
        // El servidor rechazó lo que la simulación había dado por válido
        // (condición de carrera: p.ej. otra pestaña cerró el período en el
        // medio). Se refresca el veredicto y el usuario ve el motivo real.
        const verdicts: Record<number, ServerVerdict> = {}
        for (const e of result.errors) {
          verdicts[e.row] = { ...verdicts[e.row], error: { code: e.code, message: e.message } }
        }
        for (const n of result.notices) {
          verdicts[n.row] = { ...verdicts[n.row], notice: { code: n.code, message: n.message } }
        }
        setServerVerdicts(verdicts)
        toast.error("El lote no se pudo aplicar — revisá los errores en la tabla.")
      }
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : "Error desconocido"
      toast.error(`Error al importar: ${message}`)
    } finally {
      setApplying(false)
    }
  }, [rows, fileName, fileHash, idempotencyKey, defaultPaymentMethodId, defaultBranchId, defaultCostCenterId, fallbackBankAccountId, importMutation, invalidateLedgers, onSuccess, toApiRows])

  const confirmDisabled = applying || serverLoading || errorCount > 0 || okCount === 0

  // ── Render ─────────────────────────────────────────────────────────────────
  return (
    <Dialog open={open} onOpenChange={(v) => { if (!v) reset(); onOpenChange(v) }}>
      <DialogContent className="bg-card border-border sm:max-w-[680px] max-h-[90vh] flex flex-col gap-0 p-0">

        {/* Header */}
        <div className="flex items-start justify-between gap-4 px-6 pt-6 pb-4 border-b border-border shrink-0">
          <div className="min-w-0">
            <DialogTitle className="text-base font-semibold text-card-foreground">
              Importar gastos
            </DialogTitle>
            <DialogDescription className="text-sm text-muted-foreground mt-0.5">
              Cargá un CSV con los gastos a importar
            </DialogDescription>
          </div>
          <StepIndicator current={step} />
        </div>

        {/* Body */}
        <div className="flex-1 overflow-hidden">

          {/* ── STEP 1: Upload ── */}
          {step === 1 && (
            <ScrollArea className="h-[520px]">
            <div className="flex flex-col gap-5 px-6 py-5">

              {/* Drop zone */}
              <label
                htmlFor="csv-expense-upload"
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
                  id="csv-expense-upload"
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
                    <span className="font-medium text-foreground">Descripción</span>
                    {" "}<span className="text-muted-foreground">(obligatorio)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Monto</span>
                    {" "}<span className="text-muted-foreground">(obligatorio, &gt; 0)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Categoría</span>
                    {" "}<span className="text-muted-foreground">(opcional)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Fecha</span>
                    {" "}<span className="text-muted-foreground">(opcional, hoy si vacío)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Forma de pago</span>
                    {" "}<span className="text-muted-foreground">(opcional, por nombre)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Sucursal</span>
                    {" "}<span className="text-muted-foreground">(opcional, por nombre)</span>
                  </div>
                  <div>
                    <span className="font-medium text-foreground">Centro de costo</span>
                    {" "}<span className="text-muted-foreground">(opcional, por nombre)</span>
                  </div>
                </div>
              </div>

              {/* Category reference */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Categorías válidas
                </p>
                <div className="flex flex-wrap gap-2">
                  {EXPENSE_CATEGORIES.map((cat) => (
                    <span key={cat} className="text-xs px-2 py-0.5 rounded bg-muted font-medium text-foreground">
                      {cat}
                    </span>
                  ))}
                </div>
                <p className="text-[11px] text-muted-foreground/60">
                  Si omitís la categoría o no coincide, se asignará "Otros" por defecto.
                </p>
              </div>

              {/* Valores por defecto del lote (D10) */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-3">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Valores por defecto del lote (opcionales)
                </p>
                <p className="text-[11px] text-muted-foreground">
                  Se aplican a las filas que dejen su columna vacía. Un nombre en la
                  celda que no exista en el catálogo es error de fila, nunca un
                  default silencioso.
                </p>
                <PaymentMethodSelect
                  value={defaultPaymentMethodId}
                  onChange={setDefaultPaymentMethodId}
                  context="expense"
                  label="Forma de pago por defecto"
                  showSupportText={false}
                  className="bg-background border-border text-foreground text-sm"
                />
                <BranchSelect
                  value={defaultBranchId}
                  onChange={setDefaultBranchId}
                  placeholder="Sin sucursal por defecto"
                  className="bg-background border-border text-foreground text-sm"
                />
                <CostCenterSelect
                  value={defaultCostCenterId}
                  onChange={setDefaultCostCenterId}
                  label="Centro de costo por defecto"
                  className="bg-background border-border text-foreground text-sm"
                />
                {/* BankAccountDestinationSelect gatea su propia visibilidad por
                    kind bancario Y cuentas activas (D10): 'transfer' es un kind
                    sentinela sólo para pasar ese primer filtro — el respaldo del
                    lote no está atado a UNA forma de pago puntual. */}
                <BankAccountDestinationSelect
                  paymentMethodKind="transfer"
                  value={fallbackBankAccountId}
                  onChange={setFallbackBankAccountId}
                  showEmptyNotice={false}
                  className="bg-background border-border text-foreground text-sm"
                />
              </div>

              {/* D6: la ayuda declara la verdad completa — todo o nada, y la
                  única limitación real que queda es la caja. */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Cómo se importa
                </p>
                <p className="text-[11px] text-muted-foreground">
                  El lote se aplica TODO O NADA: si una sola fila tiene un error, no se
                  importa ninguna. Los gastos por transferencia, tarjeta, cheque o
                  billetera virtual quedan registrados en la conciliación bancaria con
                  la fecha del gasto. Los gastos en EFECTIVO se registran igual, pero
                  no impactan la caja — para que un gasto en efectivo impacte el
                  arqueo, cargalo desde el formulario.
                </p>
              </div>
            </div>
            </ScrollArea>
          )}

          {/* ── STEP 2: Preview = veredicto del servidor (D9) ── */}
          {step === 2 && (
            <div className="flex flex-col h-full">

              {/* Summary bar */}
              <div className="flex items-center gap-3 px-6 py-3 border-b border-border bg-muted/10 shrink-0 flex-wrap">
                <span className="text-xs text-muted-foreground">
                  <span className="font-medium text-foreground">{rows.length}</span> filas · Archivo: {fileName}
                </span>
                <div className="flex items-center gap-2 ml-auto flex-wrap">
                  {serverLoading && (
                    <Badge variant="outline" className="text-muted-foreground text-xs gap-1">
                      <Loader2 className="h-3 w-3 animate-spin" />Validando con el servidor…
                    </Badge>
                  )}
                  {!serverLoading && (okCount - warningCount) > 0 && <Badge variant="outline" className="text-success border-success/30 text-xs">{okCount - warningCount} OK</Badge>}
                  {!serverLoading && warningCount > 0            && <Badge variant="outline" className="text-warning border-warning/30 text-xs">{warningCount} aviso{warningCount !== 1 ? "s" : ""}</Badge>}
                  {!serverLoading && errorCount > 0              && <Badge variant="outline" className="text-destructive border-destructive/30 text-xs">{errorCount} error{errorCount !== 1 ? "es" : ""}</Badge>}
                </div>
              </div>

              {/* Table — desplaza DENTRO de su contenedor, nunca ensancha el
                  documento (regla PO 2026-08-02 / responsive-shell).
                  `viewportClassName` con un `max-h-*` en PÍXELES, NUNCA un
                  `h-[Npx]`/`flex-1` en `className` (el root): el root es
                  `overflow-hidden`, así que un alto ahí sólo recorta — el
                  límite tiene que vivir en el viewport interno, exactamente
                  como ya documenta `ui/scroll-area.tsx` (bug gemelo del de la
                  campana de notificaciones, G5/H5). Un `h-full`/porcentaje en
                  el viewport tampoco alcanza contra un ancestro cuyo alto sale
                  de flex-grow — sólo un largo explícito (px) resuelve de
                  forma confiable (hallazgo real de la pasada visual de esta
                  sesión, con un CSV de 25 filas: sin esto, las filas más allá
                  de lo que entra en pantalla quedan invisibles y SIN
                  scrollbar que las alcance). */}
              <ScrollArea className="flex-1" viewportClassName="max-h-[320px]">
                {/* min-w-0 por defecto, min-w-[560px] recién desde `sm:` —
                    invertido en el código original (hallazgo real de la
                    pasada visual, 375px): con el mínimo aplicado YA en móvil,
                    la fila fuerza un scroll horizontal inútil, porque las
                    columnas que ese ancho reservaría (categoría/monto/forma de
                    pago/sucursal/estado) están las cinco `hidden sm:block` —
                    nada que revelar scrolleando. El min-width sólo hace falta
                    desde `sm:`, cuando esas columnas SÍ se muestran. */}
                <div className="px-4 py-2 min-w-0 sm:min-w-[560px] overflow-x-auto">
                  <div className="hidden sm:grid grid-cols-[32px_1fr_110px_90px_100px_90px_80px] gap-2 px-2 py-1.5 text-[11px] font-medium text-muted-foreground uppercase tracking-wide border-b border-border/50 sticky top-0 bg-card z-10">
                    <span>#</span>
                    <span>Descripción</span>
                    <span>Categoría</span>
                    <span>Monto</span>
                    <span>Forma de pago</span>
                    <span>Sucursal</span>
                    <span>Estado</span>
                  </div>

                  {rows.map((row) => {
                    const status = finalStatusFor(row)
                    const { errors: rowErrors, warnings: rowWarnings } = finalMessagesFor(row)
                    return (
                    <div
                      key={row.rowNum}
                      className={cn(
                        "grid sm:grid-cols-[32px_1fr_110px_90px_100px_90px_80px] gap-2 px-2 py-2.5 border-b border-border/40 last:border-0 items-start",
                        status === "error"   && "bg-destructive/5",
                        status === "warning" && "bg-warning/5",
                      )}
                    >
                      <span className="text-[11px] text-muted-foreground tabular-nums pt-0.5 hidden sm:block">{row.rowNum}</span>

                      <div className="min-w-0 col-span-4 sm:col-span-1">
                        <p className="text-sm font-medium text-foreground truncate">
                          {row.rawDescription || <span className="italic text-muted-foreground">sin descripción</span>}
                        </p>
                        {rowErrors.map((e, i) => (
                          <p key={i} className="text-[11px] text-destructive flex items-center gap-1 mt-0.5">
                            <XCircle className="h-3 w-3 shrink-0" />{e}
                          </p>
                        ))}
                        {rowWarnings.map((w, i) => (
                          <p key={i} className="text-[11px] text-warning flex items-center gap-1 mt-0.5">
                            <AlertTriangle className="h-3 w-3 shrink-0" />{w}
                          </p>
                        ))}
                      </div>

                      <span className="text-xs text-muted-foreground hidden sm:block pt-0.5 truncate">
                        {row.resolvedCategory}
                      </span>

                      <span className="text-xs tabular-nums font-medium text-foreground hidden sm:block pt-0.5">
                        {row.resolvedAmount > 0 ? formatAmount(row.resolvedAmount) : row.rawAmount}
                      </span>

                      <span className="text-xs text-muted-foreground hidden sm:block pt-0.5 truncate">
                        {row.rawPaymentMethod || <span className="italic">default</span>}
                      </span>

                      <span className="text-xs text-muted-foreground hidden sm:block pt-0.5 truncate">
                        {row.rawBranch || <span className="italic">default</span>}
                      </span>

                      <div className="hidden sm:block pt-0.5">
                        <StatusBadge status={status} loading={serverLoading && row.status !== "error"} />
                      </div>
                    </div>
                  )})}
                </div>
              </ScrollArea>

              {errorCount > 0 && (
                <div className="px-6 py-2.5 border-t border-border bg-muted/10 shrink-0">
                  <p className="text-xs text-muted-foreground">
                    <span className="text-destructive font-medium">{errorCount} fila{errorCount !== 1 ? "s" : ""} con error</span>
                    {" "}— el lote es todo o nada: corregí el archivo y volvé a subirlo para poder confirmar.
                  </p>
                </div>
              )}
            </div>
          )}

          {/* ── STEP 3: Result ── */}
          {step === 3 && (
            <div className="flex flex-col h-full">
              <div className="flex flex-col items-center justify-center gap-3 px-6 py-6 border-b border-border shrink-0">
                <CheckCircle2 className="h-10 w-10 text-success" />
                <div className="text-center">
                  <p className="text-base font-semibold text-foreground">
                    {serverResult?.imported ?? 0} gasto{(serverResult?.imported ?? 0) !== 1 ? "s" : ""} importado{(serverResult?.imported ?? 0) !== 1 ? "s" : ""} correctamente
                  </p>
                  <p className="text-sm text-muted-foreground mt-1">
                    Archivo: {fileName}
                  </p>
                  {serverResult?.replayed && (
                    <p className="text-sm text-warning mt-1 flex items-center justify-center gap-1.5">
                      <AlertTriangle className="h-3.5 w-3.5" />
                      Este archivo ya se había importado antes — no se creó un lote nuevo.
                    </p>
                  )}
                </div>
                <Badge variant="outline" className="text-success border-success/30">{serverResult?.imported ?? 0} importados</Badge>
              </div>

              {/* Mismo fix que el paso 2 (max-h en viewportClassName, no en el
                  root) — un lote con muchos avisos/cash_not_posted podría
                  repetir el bug si no se acota acá también. */}
              {(serverResult?.notices.length ?? 0) > 0 && (
                <ScrollArea className="flex-1" viewportClassName="max-h-[220px]">
                  <div className="px-6 py-3 flex flex-col gap-1.5">
                    <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mb-1">
                      Avisos
                    </p>
                    {serverResult?.notices.map((n, i) => (
                      <div key={i} className="flex items-start gap-2 text-xs">
                        <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">Fila {n.row}</span>
                        <span className="text-warning">{n.message}</span>
                      </div>
                    ))}
                  </div>
                </ScrollArea>
              )}
            </div>
          )}
        </div>

        {/* Footer */}
        {/* flex-wrap (hallazgo real de la pasada visual, 375px): "Cambiar
            archivo" + "Cancelar" + "Importar N gastos" (etiqueta de ancho
            variable con el conteo) no entran en una sola fila a 375px — sin
            wrap, el footer fuerza scroll horizontal en el DIÁLOGO ENTERO
            (mismo footer heredado de stock-import-adjustment-dialog.tsx). Con
            wrap, el grupo de la derecha baja a su propia fila y el botón de
            confirmación queda alcanzable sin scroll lateral. */}
        <div className="shrink-0 flex items-center justify-between flex-wrap gap-2 px-6 py-4 border-t border-border">
          <div>
            {step === 2 && (
              <Button variant="ghost" size="sm" onClick={() => setStep(1)} disabled={applying} className="gap-1.5">
                <RotateCcw className="h-3.5 w-3.5" />
                Cambiar archivo
              </Button>
            )}
          </div>

          <div className="flex items-center gap-2 flex-wrap justify-end">
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
                disabled={confirmDisabled}
                className="gap-1.5"
              >
                {applying ? (
                  <><Loader2 className="h-3.5 w-3.5 animate-spin" />Importando…</>
                ) : (
                  <>Importar {okCount} gasto{okCount !== 1 ? "s" : ""}</>
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
