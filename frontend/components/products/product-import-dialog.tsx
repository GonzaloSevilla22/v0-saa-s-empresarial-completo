"use client"

/**
 * ProductImportDialog — importador-productos-fastapi.
 *
 * 3-step import wizard for CSV product files, ahora respaldado por un LOTE
 * TRANSACCIONAL de servidor (`rpc_import_products` vía `POST /products/
 * import`, D1 del design): el archivo se aplica ENTERO o no se aplica nada
 * — nunca "importar las que se pueda". Soporta productos simples, catálogos
 * padre y variantes (Padre → Variante → Producto).
 *
 * Step 1 — Archivo
 *   Drop/select un .csv. Template descargable + referencia de columnas +
 *   tope de filas y política todo-o-nada explicados ANTES del paso 2.
 *
 * Step 2 — Revisión = VEREDICTO DEL SERVIDOR (D7)
 *   La validación de cliente (`validateImportRows`) sigue siendo la primera
 *   capa: filtra nombres faltantes, importes inválidos, categorías nuevas
 *   por sobre el tope. Las filas SIN error de cliente se resuelven
 *   (jerarquía) y se mandan al servidor en modo SIMULACIÓN (`dryRun: true`)
 *   — el servidor corre el lote completo y lo deshace, devolviendo el
 *   veredicto real: errores por fila, categorías que se crearían, cuántos
 *   productos entrarían. La confirmación se deshabilita mientras exista UNA
 *   sola fila con error (cliente o servidor) — "importar las que se pueda"
 *   ya no existe.
 *
 * Step 3 — Resultado
 *   Reporta el lote real (`dryRun: false`, misma clave de idempotencia):
 *   creados, actualizados, categorías creadas, aviso de repetición si el
 *   archivo ya se había importado.
 */

import { useState, useRef, useCallback, useEffect } from "react"
import { toast } from "sonner"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  Upload, FileText, AlertTriangle, CheckCircle2, XCircle,
  ChevronRight, Loader2, Download, RotateCcw,
} from "lucide-react"
import { useImportProducts } from "@/hooks/data/use-products"
import { useProductCategories } from "@/hooks/data/use-product-categories"
import { prepareProductImport, type PreparedImport } from "@/lib/import/importer"
import { newCategoryLimitMessage } from "@/lib/import/validator"
import { buildTemplateCsv } from "@/lib/import/template"
import { PRODUCT_IMPORT_MAX_ROWS } from "@/lib/import/types"
import { hashFileSHA256 } from "@/lib/bank-statement-parser"
import type { ValidatedImportRow } from "@/lib/import/types"
import type { ProductImportResult } from "@/lib/types"
import { cn } from "@/lib/utils"

// ── CSV template ───────────────────────────────────────────────────────────────

function downloadTemplate(csv: string) {
  const blob = new Blob(["﻿" + csv], { type: "text/csv;charset=utf-8;" })
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

// ── Row status: combinado CLIENTE + SERVIDOR (D7) ──────────────────────────────

type RowStatus = "ok" | "warning" | "error"

/** Error o aviso del servidor para una fila, indexado por número de línea. */
interface ServerVerdict {
  error?: string
}

function combinedStatus(row: ValidatedImportRow, serverVerdict: ServerVerdict | undefined): RowStatus {
  if (row.errors.length > 0)  return "error"
  if (serverVerdict?.error)   return "error"
  if (row.warnings.length > 0) return "warning"
  return "ok"
}

function RowStatusIcon({ status, loading }: { status: RowStatus; loading?: boolean }) {
  if (loading)        return <Loader2 className="h-3.5 w-3.5 text-muted-foreground animate-spin mt-0.5 shrink-0" />
  if (status === "error")   return <XCircle       className="h-3.5 w-3.5 text-destructive mt-0.5 shrink-0" />
  if (status === "warning") return <AlertTriangle className="h-3.5 w-3.5 text-warning mt-0.5 shrink-0" />
  return                     <CheckCircle2   className="h-3.5 w-3.5 text-success mt-0.5 shrink-0" />
}

// ── Component props ────────────────────────────────────────────────────────────

interface ProductImportDialogProps {
  open:         boolean
  onOpenChange: (open: boolean) => void
  onComplete:   () => void
}

type Step = 1 | 2 | 3

// ── Main component ─────────────────────────────────────────────────────────────

export function ProductImportDialog({
  open,
  onOpenChange,
  onComplete,
}: ProductImportDialogProps) {
  // productos-categorias-sku: el catálogo de la cuenta (con inactivas — una
  // desactivada se reutiliza, no se duplica) para resolver la columna
  // Categoría y generar el template.
  const { productCategories } = useProductCategories(true)
  const { importMutation, invalidateImportData } = useImportProducts()

  const [step,          setStep]         = useState<Step>(1)
  const [fileName,      setFileName]     = useState("")
  const [fileHash,      setFileHash]     = useState("")
  const [idempotencyKey, setIdempotencyKey] = useState("")
  const [prepared,      setPrepared]     = useState<PreparedImport | null>(null)
  const [applying,      setApplying]     = useState(false)
  const [dragOver,      setDragOver]     = useState(false)

  // ── Veredicto del servidor (paso 2, D7) ────────────────────────────────────
  const [serverVerdicts, setServerVerdicts] = useState<Record<number, ServerVerdict>>({})
  const [serverLoading,  setServerLoading]  = useState(false)
  const [serverResult,   setServerResult]   = useState<ProductImportResult | null>(null)
  const dryRunTriggeredRef = useRef(false)

  const fileInputRef = useRef<HTMLInputElement | null>(null)

  // ── Reset ──────────────────────────────────────────────────────────────────
  const reset = useCallback(() => {
    setStep(1)
    setFileName("")
    setFileHash("")
    setIdempotencyKey("")
    setPrepared(null)
    setApplying(false)
    setDragOver(false)
    setServerVerdicts({})
    setServerLoading(false)
    setServerResult(null)
    dryRunTriggeredRef.current = false
    if (fileInputRef.current) fileInputRef.current.value = ""
  }, [])

  function handleOpenChange(v: boolean) {
    if (!v) reset()
    onOpenChange(v)
  }

  // ── File selection ──────────────────────────────────────────────────────────
  const handleFile = useCallback(async (selected: File) => {
    setFileName(selected.name)
    setStep(2)
    setServerVerdicts({})
    setServerResult(null)
    dryRunTriggeredRef.current = false
    // Finding de revisión: elegir un SEGUNDO archivo desde el paso 2
    // ("Cambiar archivo") reseteaba el ref de forma SÍNCRONA pero dejaba
    // `prepared`/`fileHash`/`idempotencyKey` del archivo ANTERIOR vivos
    // hasta que el `await` de abajo resolviera. React corre el efecto de
    // simulación automática ANTES de esa resolución, la guarda pasaba con
    // los valores VIEJOS y la simulación del archivo nuevo nunca se
    // disparaba — se confirmaba un lote cuyo veredicto de servidor era el
    // del archivo anterior. Limpiarlos acá, síncrono, deja la guarda en
    // `false` hasta que los valores del archivo nuevo aterricen.
    setPrepared(null)
    setFileHash("")
    setIdempotencyKey("")

    try {
      const result = await prepareProductImport(selected, productCategories)
      if (result.apiRows.length > PRODUCT_IMPORT_MAX_ROWS) {
        toast.error(
          `Máximo ${PRODUCT_IMPORT_MAX_ROWS} filas por lote (recibidas ${result.apiRows.length}) — el archivo no se trocea, corregilo y volvé a subirlo.`,
        )
        setStep(1)
        return
      }
      setPrepared(result)
      // Con el tope de categorías nuevas excedido, la alerta del paso 2 ya
      // explica todo — no tiene sentido gastar la simulación de servidor en
      // un archivo que el propio cliente ya sabe que se va a rechazar.
      if (result.newCategoryLimitExceeded) {
        dryRunTriggeredRef.current = true
        return
      }
      // hashFileSHA256 (lib/bank-statement-parser.ts) — NO se reescribe un
      // segundo hasher (task 8.6).
      const hash = await hashFileSHA256(selected)
      setFileHash(hash)
      // Una clave por ARCHIVO elegido (task 8.7), no por click: la
      // simulación y la confirmación del MISMO archivo la comparten.
      setIdempotencyKey(crypto.randomUUID())
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al leer el archivo.")
      setStep(1)
    }
  }, [productCategories])

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

  // ── Simulación de servidor (D7) — extraída a función para poder
  // reintentarla desde el banner de "no se pudo validar" (finding de
  // revisión: un dry run que falla dejaba el botón de confirmar HABILITADO
  // sin que el usuario hubiera visto ningún veredicto de servidor). ────────
  const runDryRun = useCallback(() => {
    if (!prepared || !fileHash || !idempotencyKey) return
    if (prepared.apiRows.length === 0) return // nada pasó la validación de cliente
    dryRunTriggeredRef.current = true

    setServerLoading(true)
    importMutation
      .mutateAsync({
        fileName, fileHash, dryRun: true,
        idempotencyKey,
        rows: prepared.apiRows,
      })
      .then((result) => {
        setServerResult(result)
        const verdicts: Record<number, ServerVerdict> = {}
        for (const e of result.errors) {
          if (e.row != null) verdicts[e.row] = { error: e.message }
        }
        setServerVerdicts(verdicts)
      })
      .catch((err: unknown) => {
        setServerVerdicts({})
        setServerResult(null)
        const message = err instanceof Error ? err.message : "Error desconocido"
        toast.error(`No se pudo validar el archivo contra el servidor: ${message}`)
      })
      .finally(() => setServerLoading(false))
  }, [prepared, fileHash, idempotencyKey, fileName, importMutation])

  // ── Simulación automática al entrar al paso 2 (D7) ─────────────────────────
  useEffect(() => {
    if (step !== 2 || dryRunTriggeredRef.current) return
    if (!prepared || !fileHash || !idempotencyKey) return
    if (prepared.apiRows.length === 0) return // nada pasó la validación de cliente
    runDryRun()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step, prepared, fileHash, idempotencyKey])

  // ── Confirmar el lote (real, dryRun: false, MISMA clave — D7/D8) ──────────
  const handleImport = useCallback(async () => {
    if (!prepared) return
    setApplying(true)
    try {
      const result = await importMutation.mutateAsync({
        fileName, fileHash, dryRun: false,
        idempotencyKey,
        rows: prepared.apiRows,
      })
      setServerResult(result)

      if (result.committed) {
        invalidateImportData()
        setStep(3)
        onComplete()
        if (result.replayed) {
          toast.info("Este archivo ya se había importado — no se creó un lote nuevo.")
        } else {
          const totalOk = result.inserted + result.updated
          toast.success(`${totalOk} producto${totalOk !== 1 ? "s" : ""} importado${totalOk !== 1 ? "s" : ""} correctamente`)
        }
      } else {
        // El servidor rechazó lo que la simulación había dado por válido
        // (condición de carrera). Se refresca el veredicto.
        const verdicts: Record<number, ServerVerdict> = {}
        for (const e of result.errors) {
          if (e.row != null) verdicts[e.row] = { error: e.message }
        }
        setServerVerdicts(verdicts)
        toast.error("El lote no se pudo aplicar — revisá los errores en la tabla.")
      }
    } catch (err: unknown) {
      toast.error(err instanceof Error ? err.message : "Error al importar.")
    } finally {
      setApplying(false)
    }
  }, [prepared, fileName, fileHash, idempotencyKey, importMutation, invalidateImportData, onComplete])

  // ── Derived stats (estado COMBINADO cliente + servidor) ────────────────────
  const rows = prepared?.validatedRows ?? []
  const combinedStatuses = rows.map((r) => combinedStatus(r, serverVerdicts[r.lineNumber]))
  const errorCount   = combinedStatuses.filter((s) => s === "error").length
  const warningCount = combinedStatuses.filter((s) => s === "warning").length
  const okCount      = rows.length - errorCount

  const newCategories = serverResult?.newCategories ?? []
  const totalOk  = (serverResult?.inserted ?? 0) + (serverResult?.updated ?? 0)
  const totalErr = serverResult?.errors.length ?? 0

  const categoryLimitExceeded = prepared?.newCategoryLimitExceeded ?? false

  // Errores del servidor SIN fila asociada (`row: null`) — hoy sólo un
  // caller viejo podría omitir `row_no`, pero el contrato de la spec no lo
  // descarta. Antes se perdían en silencio: no entraban a `serverVerdicts`
  // (que sólo indexa por `row`) y por lo tanto no contaban en `errorCount`.
  const rowlessServerErrors = serverResult?.errors.filter((e) => e.row == null) ?? []

  // La simulación se disparó y terminó (no está cargando) pero no dejó
  // ningún veredicto — un rechazo de red, un P0400 de cuota, lo que sea.
  // Sin esto, "confirmar" quedaba habilitado sin que el usuario hubiera
  // visto NINGÚN veredicto de servidor (finding de revisión). Se excluye
  // el camino de tope de categorías: ahí el dry run se salta A PROPÓSITO
  // (ver `handleFile`) y ya está cubierto por `categoryLimitExceeded`.
  const dryRunFailed = Boolean(prepared) && !categoryLimitExceeded
    && dryRunTriggeredRef.current && !serverLoading && serverResult === null

  const confirmDisabled = applying || serverLoading || errorCount > 0
    || (prepared?.apiRows.length ?? 0) === 0 || categoryLimitExceeded
    || dryRunFailed || rowlessServerErrors.length > 0

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
            // Finding de revisión: el tope de alto iba en el ROOT
            // (`h-[560px]`), que es `overflow-hidden` — en viewports bajos
            // el padre (`flex-1 overflow-hidden` de arriba) es más corto
            // que 560px y el final del contenido quedaba recortado sin
            // forma de alcanzarlo. `h-full` deja que el root ocupe el alto
            // real que le da el layout flex del padre (mismo principio que
            // `viewportClassName`, pero acá no hace falta un tope propio:
            // el padre YA es el que acota).
            <ScrollArea className="h-full">
            <div className="flex flex-col gap-5 px-6 py-5 min-w-0">

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
                    <p className="text-xs text-muted-foreground">Incluye filas de Producto, Padre y Variante con tus categorías</p>
                  </div>
                </div>
                <Button
                  variant="outline"
                  size="sm"
                  className="gap-1.5 shrink-0"
                  onClick={() => downloadTemplate(buildTemplateCsv(productCategories))}
                >
                  <Download className="h-3.5 w-3.5" />
                  Descargar
                </Button>
              </div>

              {/* Column reference */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Columnas del CSV
                </p>
                <div className="grid grid-cols-1 sm:grid-cols-2 gap-x-6 gap-y-1.5 text-xs">
                  <div><span className="font-medium text-foreground">Nombre</span> <span className="text-muted-foreground">(obligatorio)</span></div>
                  <div><span className="font-medium text-foreground">Precio</span> <span className="text-muted-foreground">(opcional)</span></div>
                  <div><span className="font-medium text-foreground">Costo</span> <span className="text-muted-foreground">(opcional — vacía en un alta = sin costo, "0" = costo cero, vacía en un producto existente = conserva el costo que ya tenía)</span></div>
                  <div><span className="font-medium text-foreground">Categoría</span> <span className="text-muted-foreground">(opcional — se crea si no existe en tu cuenta)</span></div>
                  <div><span className="font-medium text-foreground">Stock</span> <span className="text-muted-foreground">(opcional — admite decimales, p.ej. 2,5)</span></div>
                  <div><span className="font-medium text-foreground">Stock mínimo</span> <span className="text-muted-foreground">(opcional — número entero)</span></div>
                  <div><span className="font-medium text-foreground">Código</span> <span className="text-muted-foreground">(código de barras)</span></div>
                  <div><span className="font-medium text-foreground">SKU</span> <span className="text-muted-foreground">(opcional — si coincide con uno existente, actualiza ese producto)</span></div>
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
                {/* Pasada visual (importador-productos-fastapi 10.6): `/60` bajaba el
                    contraste real a ~2.3:1 en claro / ~3.3:1 en oscuro (medido con
                    getComputedStyle + compositing de alpha real, no el valor rgba()
                    crudo) — bajo el mínimo AA de 4.5:1 para texto normal de 11px.
                    Mismo tono que el párrafo hermano de "Cómo se importa" (sin /60),
                    que sí pasa (~4.7:1 claro / ~7:1 oscuro). */}
                <p className="text-[11px] text-muted-foreground">
                  Si omitís la columna Tipo, todas las filas se importan como productos simples.
                  Las variantes se asocian automáticamente al Padre más cercano en el archivo.
                </p>
              </div>

              {/* D6/D3: tope y todo-o-nada explicados ANTES de la revisión */}
              <div className="rounded-lg border border-border bg-muted/20 px-4 py-3 flex flex-col gap-2">
                <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide">
                  Cómo se importa
                </p>
                <p className="text-[11px] text-muted-foreground">
                  El lote se aplica TODO O NADA: si una sola fila tiene un error, no se
                  importa ninguna — corregí el archivo y volvé a subirlo. Tope de{" "}
                  {PRODUCT_IMPORT_MAX_ROWS.toLocaleString("es-AR")} filas por archivo, sin trocear.
                  Volver a subir el mismo archivo no duplica el catálogo.
                </p>
              </div>
            </div>
            </ScrollArea>
          )}

          {/* ── STEP 2: Preview = veredicto del servidor (D7) ── */}
          {step === 2 && (
            <div className="flex flex-col h-full">

              {/* Summary bar */}
              <div className="flex items-center gap-3 px-6 py-3 border-b border-border bg-muted/10 shrink-0 flex-wrap">
                <span className="text-xs text-muted-foreground">
                  {prepared
                    ? <><span className="font-medium text-foreground">{rows.length}</span> filas · {fileName}</>
                    : <span className="flex items-center gap-1.5"><Loader2 className="h-3 w-3 animate-spin" />Analizando…</span>
                  }
                </span>
                {prepared && (
                  <div className="flex items-center gap-2 ml-auto flex-wrap">
                    {serverLoading && (
                      <Badge
                        variant="outline"
                        role="status"
                        aria-live="polite"
                        className="text-muted-foreground text-xs gap-1"
                      >
                        <Loader2 className="h-3 w-3 animate-spin" />Validando con el servidor…
                      </Badge>
                    )}
                    {!serverLoading && prepared.standaloneCount > 0 && <Badge variant="outline" className="text-success border-success/30 text-xs">{prepared.standaloneCount} simple{prepared.standaloneCount !== 1 ? "s" : ""}</Badge>}
                    {!serverLoading && prepared.parentCount    > 0 && <Badge variant="outline" className="text-blue-400 border-blue-500/30 text-xs">{prepared.parentCount} padre{prepared.parentCount !== 1 ? "s" : ""}</Badge>}
                    {!serverLoading && prepared.variantCount   > 0 && <Badge variant="outline" className="text-purple-400 border-purple-500/30 text-xs">{prepared.variantCount} variante{prepared.variantCount !== 1 ? "s" : ""}</Badge>}
                    {!serverLoading && warningCount   > 0 && <Badge variant="outline" className="text-warning border-warning/30 text-xs">{warningCount} advertencia{warningCount !== 1 ? "s" : ""}</Badge>}
                    {!serverLoading && errorCount     > 0 && <Badge variant="outline" className="text-destructive border-destructive/30 text-xs">{errorCount} error{errorCount !== 1 ? "es" : ""}</Badge>}
                  </div>
                )}
              </div>

              {/* Finding de revisión: la simulación contra un archivo YA
                  importado (mismo file_hash o misma clave) vuelve
                  `replayed=true` — sin este aviso, el paso 2 mostraba un
                  veredicto normal ("N productos entrarían") para un archivo
                  que confirmar no iba a volver a aplicar. */}
              {serverResult?.replayed && (
                <div role="status" className="px-6 py-2.5 border-b border-warning/30 bg-warning/5 shrink-0">
                  <p className="text-xs text-warning flex items-start gap-1.5">
                    <AlertTriangle className="h-3.5 w-3.5 shrink-0 mt-0.5" />
                    <span>Este archivo ya se había importado antes — confirmar no va a crear un lote nuevo.</span>
                  </p>
                </div>
              )}

              {/* Finding de revisión: un dry run que falla (red, P0400 de
                  cuota, lo que sea) dejaba `confirmDisabled` en false —
                  nunca se llegó a ver ningún veredicto de servidor. */}
              {dryRunFailed && (
                <div role="alert" className="px-6 py-2.5 border-b border-destructive/30 bg-destructive/5 shrink-0 flex items-center justify-between gap-2 flex-wrap">
                  <p className="text-xs text-destructive flex items-start gap-1.5">
                    <XCircle className="h-3.5 w-3.5 shrink-0 mt-0.5" />
                    <span>No se pudo validar el archivo contra el servidor — sin veredicto no se puede confirmar.</span>
                  </p>
                  <Button variant="outline" size="sm" onClick={runDryRun} className="gap-1.5 shrink-0">
                    <RotateCcw className="h-3.5 w-3.5" />
                    Reintentar
                  </Button>
                </div>
              )}

              {/* Finding de revisión: errores del servidor SIN fila asociada
                  (`row: null`) no tenían dónde mostrarse — se descartaban en
                  silencio y no bloqueaban la confirmación. */}
              {rowlessServerErrors.length > 0 && (
                <div role="alert" className="px-6 py-2.5 border-b border-destructive/30 bg-destructive/5 shrink-0">
                  <p className="text-xs font-medium text-destructive mb-1">
                    {rowlessServerErrors.length === 1
                      ? "1 error del servidor sin fila asociada"
                      : `${rowlessServerErrors.length} errores del servidor sin fila asociada`}
                  </p>
                  <ul className="space-y-0.5">
                    {rowlessServerErrors.map((e, i) => (
                      <li key={i} className="text-xs text-destructive">{e.message}</li>
                    ))}
                  </ul>
                </div>
              )}

              {/* productos-categorias-sku (D6): tope excedido — mismo
                  comportamiento previo a este change, sólo que ahora
                  también corta la simulación de servidor (no tiene sentido
                  simular un archivo que el cliente ya sabe que se rechaza). */}
              {prepared && prepared.newCategoryLimitExceeded && (
                <div role="alert" className="px-6 py-2.5 border-b border-destructive/30 bg-destructive/5 shrink-0">
                  <p className="text-xs text-destructive flex items-start gap-1.5">
                    <XCircle className="h-3.5 w-3.5 shrink-0 mt-0.5" />
                    <span>{newCategoryLimitMessage(prepared.newCategories.length, prepared.maxNewCategories)}</span>
                  </p>
                </div>
              )}

              {/* D6/D7: anuncio de categorías nuevas — del VEREDICTO DEL
                  SERVIDOR una vez que llega; mientras tanto, la conjetura
                  del cliente sirve de aviso temprano. */}
              {prepared && !prepared.newCategoryLimitExceeded && (serverResult ? newCategories.length > 0 : prepared.newCategories.length > 0) && (
                <section
                  role="region"
                  aria-label="Categorías nuevas"
                  className="px-6 py-2.5 border-b border-border bg-primary/5 shrink-0"
                >
                  <p className="text-xs text-foreground">
                    <span className="font-medium">
                      {serverResult
                        ? (newCategories.length === 1 ? "Se va a crear 1 categoría nueva" : `Se van a crear ${newCategories.length} categorías nuevas`)
                        : (prepared.newCategories.length === 1 ? "Se estima crear 1 categoría nueva" : `Se estiman crear ${prepared.newCategories.length} categorías nuevas`)
                      }
                    </span>{" "}
                    en tu cuenta al importar:
                  </p>
                  <ul className="mt-1 flex flex-wrap gap-1.5">
                    {(serverResult ? newCategories : prepared.newCategories).map((c) => (
                      <li key={c.name} className="text-xs px-2 py-0.5 rounded bg-muted text-foreground">
                        {c.name} <span className="text-muted-foreground">({c.rows} fila{c.rows !== 1 ? "s" : ""})</span>
                      </li>
                    ))}
                  </ul>
                </section>
              )}

              {/* Row list — desplaza DENTRO de su contenedor, nunca ensancha
                  el documento (regla PO 2026-08-02). `viewportClassName`
                  con un max-h en PÍXELES, NUNCA un h-[Npx]/flex-1 en
                  className (bug ya visto en el importador de gastos). */}
              <ScrollArea className="flex-1" viewportClassName="max-h-[320px]">
                <div className="px-4 py-2 space-y-0.5 min-w-0">
                  {rows.map((row) => {
                    const status  = combinedStatus(row, serverVerdicts[row.lineNumber])
                    const verdict = serverVerdicts[row.lineNumber]
                    const typeLabel  = row.rowType === "Padre"    ? "PADRE"    :
                                       row.rowType === "Variante" ? "VARIANTE" : "PRODUCTO"
                    const typeColor  = row.rowType === "Padre"    ? "text-blue-400"   :
                                       row.rowType === "Variante" ? "text-purple-400" : "text-success"
                    return (
                      <div
                        key={row.lineNumber}
                        className={cn(
                          "flex items-start gap-2 px-2 py-2 rounded text-xs",
                          status === "error"   ? "bg-destructive/5" : "",
                          status === "warning" ? "bg-warning/5"     : "",
                        )}
                      >
                        <RowStatusIcon status={status} loading={serverLoading && row.errors.length === 0} />
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
                          {(row.errors.length > 0 || row.warnings.length > 0 || verdict?.error) && (
                            <div className="mt-0.5 space-y-0.5">
                              {row.errors.map((e, i) => (
                                <p key={`c-${i}`} className="text-destructive flex items-center gap-1">
                                  <XCircle className="h-2.5 w-2.5 shrink-0" />{e}
                                </p>
                              ))}
                              {verdict?.error && (
                                <p className="text-destructive flex items-center gap-1">
                                  <XCircle className="h-2.5 w-2.5 shrink-0" />{verdict.error}
                                </p>
                              )}
                              {row.warnings.map((w, i) => (
                                <p key={`w-${i}`} className="text-warning flex items-center gap-1">
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

              {errorCount > 0 && (
                <div className="px-6 py-2.5 border-t border-border bg-muted/10 shrink-0">
                  <p id="product-import-error-summary" className="text-xs text-muted-foreground">
                    <span className="text-destructive font-medium">{errorCount} fila{errorCount !== 1 ? "s" : ""} con error</span>
                    {" "}— el lote es todo o nada: corregí el archivo y volvé a subirlo para poder confirmar.
                  </p>
                </div>
              )}
            </div>
          )}

          {/* ── STEP 3: Result ── */}
          {step === 3 && serverResult && (
            <div className="flex flex-col h-full">
              <div className="flex flex-col items-center justify-center gap-3 px-6 py-6 border-b border-border shrink-0">
                {totalErr === 0 ? (
                  <CheckCircle2 className="h-10 w-10 text-success" />
                ) : totalOk === 0 ? (
                  <XCircle className="h-10 w-10 text-destructive" />
                ) : (
                  <AlertTriangle className="h-10 w-10 text-warning" />
                )}
                <div className="text-center">
                  <p className="text-base font-semibold text-foreground">
                    {totalErr === 0
                      ? `${totalOk} producto${totalOk !== 1 ? "s" : ""} importado${totalOk !== 1 ? "s" : ""} correctamente`
                      : "No se pudo importar ningún producto"}
                  </p>
                  {serverResult.replayed && (
                    <p className="text-sm text-warning mt-1 flex items-center justify-center gap-1.5">
                      <AlertTriangle className="h-3.5 w-3.5" />
                      Este archivo ya se había importado antes — no se creó un lote nuevo.
                    </p>
                  )}
                </div>
                <div className="flex flex-wrap items-center justify-center gap-2">
                  {serverResult.inserted > 0 && <Badge variant="outline" className="text-success border-success/30">{serverResult.inserted} nuevo{serverResult.inserted !== 1 ? "s" : ""}</Badge>}
                  {serverResult.updated  > 0 && <Badge variant="outline" className="text-blue-400 border-blue-500/30">{serverResult.updated} actualizado{serverResult.updated !== 1 ? "s" : ""}</Badge>}
                  {newCategories.length  > 0 && <Badge variant="outline" className="text-blue-400 border-blue-500/30">{newCategories.length} categoría{newCategories.length !== 1 ? "s" : ""} nueva{newCategories.length !== 1 ? "s" : ""}</Badge>}
                  {totalErr > 0 && <Badge variant="outline" className="text-destructive border-destructive/30">{totalErr} error{totalErr !== 1 ? "es" : ""}</Badge>}
                </div>
              </div>

              {totalErr > 0 && (
                <ScrollArea className="flex-1" viewportClassName="max-h-[220px]">
                  <div className="px-6 py-3 flex flex-col gap-1.5">
                    <p className="text-xs font-semibold text-muted-foreground uppercase tracking-wide mb-1">
                      Detalle de errores
                    </p>
                    {serverResult.errors.map((e, i) => (
                      <div key={i} className="flex items-start gap-2 text-xs">
                        {e.row != null && (
                          <span className="text-muted-foreground tabular-nums shrink-0 pt-0.5">L{e.row}</span>
                        )}
                        {e.name && (
                          <span className="font-medium text-foreground shrink-0 truncate max-w-[160px]">{e.name}</span>
                        )}
                        <span className="text-destructive">{e.message}</span>
                      </div>
                    ))}
                  </div>
                </ScrollArea>
              )}
            </div>
          )}
        </div>

        {/* Footer — flex-wrap: "Cambiar archivo" + "Cancelar" + "Importar N
            filas" no entran en una sola fila a 375px (bug ya visto en el
            importador de gastos). */}
        <div className="shrink-0 flex items-center justify-between flex-wrap gap-2 px-6 py-4 border-t border-border relative z-30">
          <div>
            {step === 2 && !applying && (
              <Button variant="ghost" size="sm" onClick={() => setStep(1)} className="gap-1.5">
                <RotateCcw className="h-3.5 w-3.5" />
                Cambiar archivo
              </Button>
            )}
          </div>

          <div className="flex items-center gap-2 flex-wrap justify-end">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => handleOpenChange(false)}
              disabled={applying}
            >
              {step === 3 ? "Cerrar" : "Cancelar"}
            </Button>

            {step === 2 && prepared && (
              <Button
                size="sm"
                onClick={handleImport}
                disabled={confirmDisabled}
                aria-describedby={errorCount > 0 ? "product-import-error-summary" : undefined}
                className="gap-1.5"
              >
                {applying ? (
                  <><Loader2 className="h-3.5 w-3.5 animate-spin" />Importando…</>
                ) : serverResult?.replayed ? (
                  <>Confirmar (ya importado)</>
                ) : (
                  <>Importar {okCount} fila{okCount !== 1 ? "s" : ""}</>
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
