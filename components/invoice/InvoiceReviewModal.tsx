"use client"

import { useState, useCallback, useMemo } from "react"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogFooter,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Badge } from "@/components/ui/badge"
import { ScrollArea } from "@/components/ui/scroll-area"
import { Separator } from "@/components/ui/separator"
import { InvoiceProductRow } from "@/components/invoice/InvoiceProductRow"
import {
  ShoppingBag, Building2, Calendar, FileText, AlertTriangle,
  CheckCircle, Loader2, DollarSign,
} from "lucide-react"
import { toast } from "sonner"
import { generateOperationId } from "@/lib/cart-utils"
import type { MatchedInvoiceLine, ParsedInvoice } from "@/lib/invoice-types"
import type { Product, UnitOfMeasure } from "@/lib/types"

interface Props {
  open:         boolean
  onOpenChange: (open: boolean) => void
  parsed:       ParsedInvoice
  lines:        MatchedInvoiceLine[]
  products:     Product[]
  units:        UnitOfMeasure[]
  documentId:   string | null
  onConfirm: (
    lines:       MatchedInvoiceLine[],
    operationId: string,
    parsed:      ParsedInvoice,
    documentId:  string | null,
  ) => Promise<void>
}

export function InvoiceReviewModal({
  open, onOpenChange, parsed, lines: initialLines,
  products, units, documentId, onConfirm,
}: Props) {
  const [lines,       setLines]       = useState<MatchedInvoiceLine[]>(initialLines)
  const [confirming,  setConfirming]  = useState(false)

  // Reset when modal reopens with new data
  // (parent passes fresh initialLines each time)

  const updateLine = useCallback((index: number, updates: Partial<MatchedInvoiceLine>) => {
    setLines((prev) => prev.map((l, i) => i === index ? { ...l, ...updates } : l))
  }, [])

  const removeLine = useCallback((index: number) => {
    setLines((prev) => prev.filter((_, i) => i !== index))
  }, [])

  const includedLines = useMemo(() => lines.filter((l) => l.included), [lines])

  const hasErrors = useMemo(
    () => includedLines.some((l) => !l.confirmed_product_id && !l.is_new_product),
    [includedLines],
  )

  const estimatedTotal = useMemo(
    () => includedLines.reduce(
      (sum, l) => sum + l.confirmed_quantity * l.confirmed_unit_price, 0
    ),
    [includedLines],
  )

  const newProducts  = useMemo(() => includedLines.filter((l) => l.is_new_product),  [includedLines])
  const warnings     = parsed.warnings ?? []

  async function handleConfirm() {
    if (includedLines.length === 0) {
      toast.error("No hay productos seleccionados")
      return
    }
    const missingPrice = includedLines.filter((l) => l.confirmed_unit_price <= 0)
    if (missingPrice.length > 0) {
      toast.error(`Completá el precio de: ${missingPrice.map((l) => l.confirmed_product_name).join(", ")}`)
      return
    }

    setConfirming(true)
    try {
      const operationId = generateOperationId()
      await onConfirm(includedLines, operationId, parsed, documentId)
      onOpenChange(false)
    } catch (err: any) {
      toast.error(err.message || "Error al confirmar la compra")
    } finally {
      setConfirming(false)
    }
  }
  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="bg-card border-border max-w-2xl max-h-[90vh] flex flex-col p-0">
        {/* ── Header ───────────────────────────────────────────────────────── */}
        <DialogHeader className="px-6 pt-6 pb-4 border-b border-border shrink-0">
          <div className="flex items-center justify-between">
            <DialogTitle className="text-lg font-bold text-card-foreground flex items-center gap-2">
              <ShoppingBag className="h-5 w-5 text-primary" />
              Revisar Compra
            </DialogTitle>
            <Badge
              variant="outline"
              className={`text-[11px] ${
                (parsed.confidence ?? 0) >= 0.85
                  ? "border-emerald-500/40 text-emerald-400"
                  : "border-yellow-500/40 text-yellow-400"
              }`}
            >
              Confianza IA: {Math.round((parsed.confidence ?? 0) * 100)}%
            </Badge>
          </div>

          {/* Invoice header data */}
          <div className="grid grid-cols-2 sm:grid-cols-3 gap-3 mt-3">
            {parsed.supplier?.name && (
              <div className="flex items-center gap-2 text-xs">
                <Building2 className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                <div>
                  <p className="text-muted-foreground">Proveedor</p>
                  <p className="font-medium text-foreground truncate max-w-[140px]">
                    {parsed.supplier.name}
                  </p>
                </div>
              </div>
            )}
            {parsed.invoice?.date && (
              <div className="flex items-center gap-2 text-xs">
                <Calendar className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                <div>
                  <p className="text-muted-foreground">Fecha</p>
                  <p className="font-medium text-foreground">{parsed.invoice.date}</p>
                </div>
              </div>
            )}
            {parsed.invoice?.number && (
              <div className="flex items-center gap-2 text-xs">
                <FileText className="h-3.5 w-3.5 text-muted-foreground shrink-0" />
                <div>
                  <p className="text-muted-foreground">N° Factura</p>
                  <p className="font-medium text-foreground">{parsed.invoice.number}</p>
                </div>
              </div>
            )}
          </div>

          {/* Warnings */}
          {warnings.length > 0 && (
            <div className="mt-3 flex items-start gap-2 rounded-lg border border-yellow-500/30 bg-yellow-500/5 px-3 py-2">
              <AlertTriangle className="h-4 w-4 text-yellow-400 shrink-0 mt-0.5" />
              <ul className="text-xs text-yellow-400 space-y-0.5">
                {warnings.map((w, i) => <li key={i}>{w}</li>)}
              </ul>
            </div>
          )}
        </DialogHeader>

        {/* ── Products list ─────────────────────────────────────────────────── */}
        <ScrollArea className="flex-1 px-6 py-4">
          <div className="flex flex-col gap-2">
            <div className="flex items-center justify-between mb-1">
              <p className="text-[11px] font-semibold uppercase tracking-wider text-muted-foreground">
                {lines.length} producto{lines.length !== 1 ? "s" : ""} detectado{lines.length !== 1 ? "s" : ""}
              </p>
              {newProducts.length > 0 && (
                <span className="text-[11px] text-blue-400">
                  {newProducts.length} nuevo{newProducts.length > 1 ? "s" : ""} — verificá nombre
                </span>
              )}
            </div>

            {lines.map((line, i) => (
              <InvoiceProductRow
                key={i}
                index={i}
                line={line}
                products={products}
                units={units}
                onChange={updateLine}
                onRemove={removeLine}
              />
            ))}
          </div>
        </ScrollArea>

        {/* ── Footer ───────────────────────────────────────────────────────── */}
        <div className="border-t border-border px-6 py-4 shrink-0">
          {/* Summary */}
          <div className="flex items-center justify-between mb-4">
            <div className="text-sm text-muted-foreground">
              <span className="font-medium text-foreground">{includedLines.length}</span>
              /{lines.length} productos incluidos
            </div>
            <div className="flex items-center gap-2">
              <DollarSign className="h-4 w-4 text-muted-foreground" />
              <span className="text-lg font-bold text-primary tabular-nums">
                ${estimatedTotal.toLocaleString("es-AR", { minimumFractionDigits: 2 })}
              </span>
            </div>
          </div>

          <div className="flex gap-3">
            <Button
              variant="outline"
              className="flex-1"
              onClick={() => onOpenChange(false)}
              disabled={confirming}
            >
              Cancelar
            </Button>
            <Button
              className="flex-1 gap-2"
              onClick={handleConfirm}
              disabled={confirming || includedLines.length === 0 || hasErrors}
            >
              {confirming ? (
                <><Loader2 className="h-4 w-4 animate-spin" />Registrando...</>
              ) : (
                <><CheckCircle className="h-4 w-4" />Confirmar compra ({includedLines.length})</>
              )}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}