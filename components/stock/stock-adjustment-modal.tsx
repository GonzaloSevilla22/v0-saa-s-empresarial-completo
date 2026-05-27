"use client"

/**
 * StockAdjustmentModal
 *
 * Manual inventory adjustment dialog supporting multiple products in one shot.
 *
 * UX:
 *   - Global settings: movement type, reason, notes (shared across all products).
 *   - Product rows: each row has its own product selector + quantity field.
 *   - "Agregar producto" button lets users queue up several adjustments at once.
 *   - When opened from a row's AdjustButton, the first product is pre-filled.
 *
 * Submit:
 *   - Calls rpc_stock_adjustment once per row, sequentially.
 *   - Shows a single summary toast: "3 productos ajustados" or "2 OK · 1 error".
 *   - On partial error, the modal stays open so the user can see which rows failed.
 *
 * Race-condition note (physical_count):
 *   For physical_count we pass p_target_quantity (absolute value) to the RPC
 *   instead of a pre-computed delta. The RPC acquires a FOR UPDATE lock on the
 *   product row BEFORE computing the delta, so it always uses the real current
 *   stock — not the potentially stale value shown in the UI.
 */

import { useState, useCallback, useMemo, useRef } from "react"
import { createClient } from "@/lib/supabase/client"
import { useData } from "@/contexts/data-context"
import { toast } from "sonner"
import {
  Dialog, DialogContent, DialogHeader, DialogTitle, DialogDescription,
} from "@/components/ui/dialog"
import { Button } from "@/components/ui/button"
import { Input } from "@/components/ui/input"
import { Label } from "@/components/ui/label"
import { Textarea } from "@/components/ui/textarea"
import { ScrollArea } from "@/components/ui/scroll-area"
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import {
  ArrowDownCircle, ArrowUpCircle, ClipboardList,
  AlertTriangle, Wrench, Timer, ArrowRightLeft,
  Loader2, Plus, X,
} from "lucide-react"
import type { Product, MovementType } from "@/lib/types"
import { cn } from "@/lib/utils"

// ── Movement type registry ─────────────────────────────────────────────────────

interface MovementOption {
  uiKey:       string
  type:        MovementType
  /** +1 = add, -1 = remove, 0 = absolute (physical_count) */
  sign:        1 | -1 | 0
  label:       string
  description: string
  icon:        React.ReactNode
  color:       string
  bg:          string
}

const MOVEMENT_OPTIONS: MovementOption[] = [
  {
    uiKey: "adjustment_in",  type: "adjustment",   sign:  1,
    label: "Ajuste de entrada",    description: "Aumentar stock manualmente",
    icon: <ArrowUpCircle   className="h-4 w-4" />, color: "text-emerald-400", bg: "bg-emerald-500/10 border-emerald-500/20",
  },
  {
    uiKey: "adjustment_out", type: "adjustment",   sign: -1,
    label: "Ajuste de salida",     description: "Reducir stock manualmente",
    icon: <ArrowDownCircle className="h-4 w-4" />, color: "text-yellow-400",  bg: "bg-yellow-500/10 border-yellow-500/20",
  },
  {
    uiKey: "physical_count", type: "physical_count", sign: 0,
    label: "Conteo físico",        description: "Ajustar al stock real contado",
    icon: <ClipboardList   className="h-4 w-4" />, color: "text-blue-400",    bg: "bg-blue-500/10 border-blue-500/20",
  },
  {
    uiKey: "loss",           type: "loss",          sign: -1,
    label: "Pérdida / Robo",       description: "Mercadería extraviada o robada",
    icon: <AlertTriangle   className="h-4 w-4" />, color: "text-red-400",     bg: "bg-red-500/10 border-red-500/20",
  },
  {
    uiKey: "damage",         type: "damage",        sign: -1,
    label: "Daño / Merma",         description: "Productos dañados o mermados",
    icon: <Wrench          className="h-4 w-4" />, color: "text-orange-400",  bg: "bg-orange-500/10 border-orange-500/20",
  },
  {
    uiKey: "expiry",         type: "expiry",        sign: -1,
    label: "Vencimiento",          description: "Productos vencidos dados de baja",
    icon: <Timer           className="h-4 w-4" />, color: "text-purple-400",  bg: "bg-purple-500/10 border-purple-500/20",
  },
  {
    uiKey: "transfer_in",    type: "transfer_in",   sign:  1,
    label: "Transferencia entrada", description: "Stock recibido desde otro depósito",
    icon: <ArrowRightLeft  className="h-4 w-4" />, color: "text-teal-400",    bg: "bg-teal-500/10 border-teal-500/20",
  },
  {
    uiKey: "transfer_out",   type: "transfer_out",  sign: -1,
    label: "Transferencia salida",  description: "Stock enviado a otro depósito",
    icon: <ArrowRightLeft  className="h-4 w-4 rotate-90" />, color: "text-slate-400", bg: "bg-slate-500/10 border-slate-500/20",
  },
]

const OPTION_BY_KEY = Object.fromEntries(
  MOVEMENT_OPTIONS.map((o) => [o.uiKey, o]),
) as Record<string, MovementOption>

// ── Types ──────────────────────────────────────────────────────────────────────

interface AdjustItem {
  /** Stable local key for React list reconciliation */
  key:       string
  productId: string
  quantity:  string
  /** Set after submit attempt to show per-row error */
  error?:    string
}

// ── Props ──────────────────────────────────────────────────────────────────────

interface StockAdjustmentModalProps {
  open:         boolean
  onOpenChange: (open: boolean) => void
  /** Pre-selected product (from per-row AdjustButton). */
  product?:     Product
  onSuccess?:   () => void
}

// ── Helpers ────────────────────────────────────────────────────────────────────

function makeKey() {
  return `${Date.now()}-${Math.random().toString(36).slice(2, 7)}`
}

function makeItem(productId = ""): AdjustItem {
  return { key: makeKey(), productId, quantity: "" }
}

// ── Component ─────────────────────────────────────────────────────────────────

export function StockAdjustmentModal({
  open,
  onOpenChange,
  product: propProduct,
  onSuccess,
}: StockAdjustmentModalProps) {
  const { products, refreshData } = useData()
  const supabase = createClient()

  // ── Global form state ────────────────────────────────────────────────────────
  const [movementKey, setMovementKey] = useState<string>("adjustment_in")
  const [reason,      setReason]      = useState<string>("")
  const [notes,       setNotes]       = useState<string>("")
  const [loading,     setLoading]     = useState(false)

  // ── Product rows ─────────────────────────────────────────────────────────────
  const [items, setItems] = useState<AdjustItem[]>(() => [
    makeItem(propProduct?.id ?? ""),
  ])

  const option        = OPTION_BY_KEY[movementKey] ?? MOVEMENT_OPTIONS[0]
  const isPhysicalCount = option.sign === 0

  // Trackable, non-parent products only
  const adjustableProducts = useMemo(
    () => products.filter(
      (p) => p.stockControlType !== "variant_only" && p.stockControlType !== "untracked",
    ),
    [products],
  )

  // ── Row helpers ──────────────────────────────────────────────────────────────
  const addItem = useCallback(() => {
    setItems((prev) => [...prev, makeItem()])
  }, [])

  const removeItem = useCallback((key: string) => {
    setItems((prev) => prev.length > 1 ? prev.filter((i) => i.key !== key) : prev)
  }, [])

  const updateItem = useCallback((key: string, field: "productId" | "quantity", value: string) => {
    setItems((prev) =>
      prev.map((i) => i.key === key ? { ...i, [field]: value, error: undefined } : i),
    )
  }, [])

  const setItemError = useCallback((key: string, error: string) => {
    setItems((prev) => prev.map((i) => i.key === key ? { ...i, error } : i))
  }, [])

  // ── Reset ────────────────────────────────────────────────────────────────────
  const resetForm = useCallback(() => {
    setItems([makeItem(propProduct?.id ?? "")])
    setMovementKey("adjustment_in")
    setReason("")
    setNotes("")
  }, [propProduct?.id])

  // ── Submit ───────────────────────────────────────────────────────────────────
  const handleSubmit = useCallback(async () => {
    // Client-side validation
    let hasError = false
    const validated = items.map((item) => {
      const parsedQty = parseFloat(item.quantity)
      if (!item.productId) {
        setItemError(item.key, "Seleccioná un producto")
        hasError = true
      } else if (item.quantity === "" || isNaN(parsedQty) || parsedQty < 0) {
        setItemError(item.key, "Cantidad inválida")
        hasError = true
      } else if (!isPhysicalCount && parsedQty <= 0) {
        setItemError(item.key, "La cantidad debe ser mayor a cero")
        hasError = true
      }
      return { ...item, parsedQty }
    })
    if (hasError) return

    setLoading(true)
    let successCount = 0
    let errorCount   = 0

    for (const item of validated) {
      const rpcParams: Record<string, unknown> = {
        p_product_id: item.productId,
        p_type:       option.type,
        p_reason:     reason.trim() || null,
        p_notes:      notes.trim()  || null,
      }

      if (isPhysicalCount) {
        rpcParams.p_target_quantity = item.parsedQty
      } else {
        rpcParams.p_quantity_delta = item.parsedQty * option.sign
      }

      const { error } = await supabase.rpc("rpc_stock_adjustment", rpcParams)

      if (error) {
        setItemError(item.key, error.message)
        errorCount++
      } else {
        successCount++
      }
    }

    setLoading(false)

    if (errorCount === 0) {
      toast.success(
        successCount === 1
          ? `Ajuste registrado correctamente`
          : `${successCount} productos ajustados correctamente`,
      )
      await refreshData()
      resetForm()
      onOpenChange(false)
      onSuccess?.()
    } else {
      await refreshData()
      if (successCount > 0) {
        toast.warning(
          `${successCount} ajuste${successCount !== 1 ? "s" : ""} OK · ` +
          `${errorCount} con error — revisá las filas marcadas`,
        )
      } else {
        toast.error("No se pudo registrar ningún ajuste. Revisá los errores.")
      }
    }
  }, [
    items, isPhysicalCount, option, reason, notes,
    supabase, refreshData, resetForm, onOpenChange, onSuccess, setItemError,
  ])

  // ── Render ───────────────────────────────────────────────────────────────────
  return (
    <Dialog
      open={open}
      onOpenChange={(v) => {
        if (!v) resetForm()
        onOpenChange(v)
      }}
    >
      <DialogContent className="bg-card border-border sm:max-w-[560px] max-h-[90vh] flex flex-col">
        <DialogHeader className="shrink-0">
          <DialogTitle className="text-card-foreground text-base font-semibold">
            Ajuste de inventario
          </DialogTitle>
          <DialogDescription className="text-muted-foreground text-sm">
            Registrá uno o varios ajustes manuales de stock con trazabilidad completa.
          </DialogDescription>
        </DialogHeader>

        {/* Scrollable body */}
        <ScrollArea className="flex-1 overflow-y-auto -mx-6 px-6">
          <div className="flex flex-col gap-4 pt-1 pb-2">

            {/* ── Movement type (global) ── */}
            <div className="flex flex-col gap-1.5">
              <Label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                Tipo de movimiento
              </Label>
              <Select value={movementKey} onValueChange={setMovementKey}>
                <SelectTrigger className="bg-background border-border text-foreground">
                  <SelectValue />
                </SelectTrigger>
                <SelectContent className="bg-card border-border">
                  {MOVEMENT_OPTIONS.map((o) => (
                    <SelectItem key={o.uiKey} value={o.uiKey}>
                      <div className="flex items-center gap-2">
                        <span className={o.color}>{o.icon}</span>
                        <span>{o.label}</span>
                        <span className="text-muted-foreground text-xs hidden sm:inline">
                          — {o.description}
                        </span>
                      </div>
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              {/* Type description chip */}
              <div className={cn(
                "flex items-center gap-2 px-3 py-1.5 rounded-md border text-xs font-medium",
                option.bg, option.color,
              )}>
                {option.icon}
                <span>{option.description}</span>
              </div>
            </div>

            {/* ── Product rows ── */}
            <div className="flex flex-col gap-1.5">
              <Label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                Productos
              </Label>

              <div className="flex flex-col gap-2">
                {items.map((item, idx) => (
                  <ProductRow
                    key={item.key}
                    item={item}
                    idx={idx}
                    isFirst={idx === 0}
                    propProduct={propProduct}
                    adjustableProducts={adjustableProducts}
                    allProducts={products}
                    isPhysicalCount={isPhysicalCount}
                    option={option}
                    canRemove={items.length > 1}
                    onProductChange={(val) => updateItem(item.key, "productId", val)}
                    onQuantityChange={(val) => updateItem(item.key, "quantity", val)}
                    onRemove={() => removeItem(item.key)}
                  />
                ))}
              </div>

              <Button
                type="button"
                variant="ghost"
                size="sm"
                className="w-full h-8 border border-dashed border-border text-muted-foreground hover:text-foreground hover:bg-muted/40 mt-1 gap-1.5"
                onClick={addItem}
                disabled={loading}
              >
                <Plus className="h-3.5 w-3.5" />
                Agregar producto
              </Button>
            </div>

            {/* ── Reason (global) ── */}
            <div className="flex flex-col gap-1.5">
              <Label
                htmlFor="adj-reason"
                className="text-xs font-medium text-muted-foreground uppercase tracking-wide"
              >
                Motivo <span className="text-muted-foreground/60 normal-case">(opcional)</span>
              </Label>
              <Input
                id="adj-reason"
                placeholder="Ej: Conteo semestral, Devolución proveedor…"
                value={reason}
                onChange={(e) => setReason(e.target.value)}
                className="bg-background border-border text-foreground"
              />
            </div>

            {/* ── Notes (global) ── */}
            <div className="flex flex-col gap-1.5">
              <Label
                htmlFor="adj-notes"
                className="text-xs font-medium text-muted-foreground uppercase tracking-wide"
              >
                Notas <span className="text-muted-foreground/60 normal-case">(opcional)</span>
              </Label>
              <Textarea
                id="adj-notes"
                placeholder="Detalles adicionales…"
                value={notes}
                onChange={(e) => setNotes(e.target.value)}
                className="bg-background border-border text-foreground resize-none min-h-[56px]"
              />
            </div>
          </div>
        </ScrollArea>

        {/* ── Footer actions (sticky) ── */}
        <div className="shrink-0 flex items-center justify-between gap-2 pt-3 border-t border-border mt-2">
          <span className="text-xs text-muted-foreground">
            {items.length} producto{items.length !== 1 ? "s" : ""}
          </span>
          <div className="flex items-center gap-2">
            <Button
              variant="ghost"
              size="sm"
              onClick={() => { resetForm(); onOpenChange(false) }}
              disabled={loading}
            >
              Cancelar
            </Button>
            <Button
              size="sm"
              onClick={handleSubmit}
              disabled={loading || items.every((i) => !i.productId || !i.quantity)}
            >
              {loading ? (
                <><Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />Guardando…</>
              ) : items.length === 1 ? (
                "Registrar ajuste"
              ) : (
                `Registrar ${items.length} ajustes`
              )}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}

// ── Product row sub-component ─────────────────────────────────────────────────

interface ProductRowProps {
  item:               AdjustItem
  idx:                number
  isFirst:            boolean
  propProduct?:       Product
  adjustableProducts: Product[]
  allProducts:        Product[]
  isPhysicalCount:    boolean
  option:             MovementOption
  canRemove:          boolean
  onProductChange:    (val: string) => void
  onQuantityChange:   (val: string) => void
  onRemove:           () => void
}

function ProductRow({
  item,
  idx,
  isFirst,
  propProduct,
  adjustableProducts,
  allProducts,
  isPhysicalCount,
  option,
  canRemove,
  onProductChange,
  onQuantityChange,
  onRemove,
}: ProductRowProps) {
  const activeProduct = propProduct && isFirst
    ? propProduct
    : allProducts.find((p) => p.id === item.productId)

  const parsedQty   = parseFloat(item.quantity)
  const previewDelta: number | null = useMemo(() => {
    if (isNaN(parsedQty) || parsedQty < 0) return null
    if (isPhysicalCount) {
      if (!activeProduct) return null
      return parsedQty - activeProduct.stock
    }
    return parsedQty * option.sign
  }, [parsedQty, isPhysicalCount, activeProduct, option.sign])

  // Products already selected in other rows (to prevent duplicates)
  // Note: we don't filter here to keep the dropdown simple — duplicates are
  // caught at submit time by the RPC (which re-locks the product row).
  const isFixed = propProduct && isFirst

  return (
    <div className={cn(
      "rounded-lg border bg-muted/20 p-3 flex flex-col gap-2 relative",
      item.error ? "border-red-500/40 bg-red-500/5" : "border-border",
    )}>
      {/* Row header */}
      <div className="flex items-center justify-between gap-2">
        <span className="text-xs font-medium text-muted-foreground">
          Producto {idx + 1}
        </span>
        {canRemove && (
          <button
            type="button"
            onClick={onRemove}
            className="text-muted-foreground/50 hover:text-foreground transition-colors"
            title="Quitar fila"
          >
            <X className="h-3.5 w-3.5" />
          </button>
        )}
      </div>

      {/* Product selector / chip */}
      {isFixed ? (
        /* Pre-selected product chip */
        <div className="flex items-center gap-2 rounded-md border border-border bg-background px-3 py-2">
          <div className="min-w-0 flex-1">
            <p className="text-sm font-medium text-foreground truncate">{propProduct!.name}</p>
            <p className="text-xs text-muted-foreground">
              Stock actual: <span className="font-medium tabular-nums">{propProduct!.stock}</span>
            </p>
          </div>
        </div>
      ) : (
        <Select value={item.productId} onValueChange={onProductChange}>
          <SelectTrigger className="bg-background border-border text-foreground">
            <SelectValue placeholder="Seleccioná un producto…" />
          </SelectTrigger>
          <SelectContent className="bg-card border-border max-h-60 overflow-y-auto">
            {adjustableProducts.map((p) => (
              <SelectItem key={p.id} value={p.id}>
                <span className="font-medium">{p.name}</span>
                <span className="text-muted-foreground ml-2 text-xs tabular-nums">
                  Stock: {p.stock}
                </span>
              </SelectItem>
            ))}
          </SelectContent>
        </Select>
      )}

      {/* Quantity */}
      <div className="flex items-center gap-2">
        <Input
          type="number"
          min={0}
          step="any"
          placeholder={isPhysicalCount ? "Cantidad total contada…" : "Cantidad…"}
          value={item.quantity}
          onChange={(e) => onQuantityChange(e.target.value)}
          className="bg-background border-border text-foreground flex-1"
        />
        {/* Inline delta preview */}
        {activeProduct && item.quantity !== "" && previewDelta !== null && (
          <span className={cn(
            "text-xs font-semibold tabular-nums shrink-0",
            previewDelta > 0 ? "text-emerald-400" : previewDelta < 0 ? "text-red-400" : "text-muted-foreground",
          )}>
            {previewDelta > 0 ? "+" : ""}{previewDelta}
            {isPhysicalCount && (
              <span className="text-muted-foreground/60 font-normal ml-0.5">*</span>
            )}
          </span>
        )}
      </div>

      {/* Physical count full preview */}
      {isPhysicalCount && activeProduct && item.quantity !== "" && previewDelta !== null && (
        <p className="text-[11px] text-muted-foreground/70">
          {activeProduct.stock} → {activeProduct.stock + previewDelta}
          {" "}<span className="opacity-60">(* el servidor confirma al guardar)</span>
        </p>
      )}

      {/* Per-row error */}
      {item.error && (
        <p className="text-xs text-red-400 flex items-center gap-1">
          <AlertTriangle className="h-3 w-3 shrink-0" />
          {item.error}
        </p>
      )}
    </div>
  )
}
