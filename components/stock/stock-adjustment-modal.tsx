"use client"

/**
 * StockAdjustmentModal
 *
 * Manual inventory adjustment dialog.
 * Supports 8 movement types mapped to a user-friendly selector:
 *   adjustment+, adjustment-, physical_count, loss, damage, expiry,
 *   transfer_in, transfer_out
 *
 * For `physical_count` the user enters the NEW absolute stock value;
 * the delta is computed as (newQty - currentStock) before calling the RPC.
 * For all other types the user enters a positive quantity; the component
 * applies the correct sign before calling the RPC.
 *
 * Props:
 *   open          — controlled dialog open state
 *   onOpenChange  — setter for open state
 *   product       — pre-selected product (skip the product dropdown)
 *   onSuccess     — callback after a successful adjustment
 */

import { useState, useCallback, useMemo } from "react"
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
import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Badge } from "@/components/ui/badge"
import {
  ArrowDownCircle, ArrowUpCircle, ClipboardList,
  AlertTriangle, Wrench, Timer, ArrowRightLeft, Loader2,
} from "lucide-react"
import type { Product, MovementType } from "@/lib/types"
import { cn } from "@/lib/utils"

// ── Movement type registry ─────────────────────────────────────────────────────

interface MovementOption {
  /** UI key — used in the Select, not sent to DB */
  uiKey:   string
  /** DB type */
  type:    MovementType
  /** +1 = add stock, -1 = remove stock, 0 = absolute (physical_count) */
  sign:    1 | -1 | 0
  label:   string
  description: string
  icon:    React.ReactNode
  color:   string  // tailwind text-* class for the badge
  bg:      string  // tailwind bg-* class
}

const MOVEMENT_OPTIONS: MovementOption[] = [
  {
    uiKey:       "adjustment_in",
    type:        "adjustment",
    sign:        1,
    label:       "Ajuste de entrada",
    description: "Aumentar stock manualmente",
    icon:        <ArrowUpCircle className="h-4 w-4" />,
    color:       "text-emerald-400",
    bg:          "bg-emerald-500/10 border-emerald-500/20",
  },
  {
    uiKey:       "adjustment_out",
    type:        "adjustment",
    sign:        -1,
    label:       "Ajuste de salida",
    description: "Reducir stock manualmente",
    icon:        <ArrowDownCircle className="h-4 w-4" />,
    color:       "text-yellow-400",
    bg:          "bg-yellow-500/10 border-yellow-500/20",
  },
  {
    uiKey:       "physical_count",
    type:        "physical_count",
    sign:        0,
    label:       "Conteo físico",
    description: "Ajustar al stock real contado",
    icon:        <ClipboardList className="h-4 w-4" />,
    color:       "text-blue-400",
    bg:          "bg-blue-500/10 border-blue-500/20",
  },
  {
    uiKey:       "loss",
    type:        "loss",
    sign:        -1,
    label:       "Pérdida / Robo",
    description: "Mercadería extraviada o robada",
    icon:        <AlertTriangle className="h-4 w-4" />,
    color:       "text-red-400",
    bg:          "bg-red-500/10 border-red-500/20",
  },
  {
    uiKey:       "damage",
    type:        "damage",
    sign:        -1,
    label:       "Daño / Merma",
    description: "Productos dañados o mermados",
    icon:        <Wrench className="h-4 w-4" />,
    color:       "text-orange-400",
    bg:          "bg-orange-500/10 border-orange-500/20",
  },
  {
    uiKey:       "expiry",
    type:        "expiry",
    sign:        -1,
    label:       "Vencimiento",
    description: "Productos vencidos dados de baja",
    icon:        <Timer className="h-4 w-4" />,
    color:       "text-purple-400",
    bg:          "bg-purple-500/10 border-purple-500/20",
  },
  {
    uiKey:       "transfer_in",
    type:        "transfer_in",
    sign:        1,
    label:       "Transferencia entrada",
    description: "Stock recibido desde otro depósito",
    icon:        <ArrowRightLeft className="h-4 w-4" />,
    color:       "text-teal-400",
    bg:          "bg-teal-500/10 border-teal-500/20",
  },
  {
    uiKey:       "transfer_out",
    type:        "transfer_out",
    sign:        -1,
    label:       "Transferencia salida",
    description: "Stock enviado a otro depósito",
    icon:        <ArrowRightLeft className="h-4 w-4 rotate-90" />,
    color:       "text-slate-400",
    bg:          "bg-slate-500/10 border-slate-500/20",
  },
]

const OPTION_BY_KEY = Object.fromEntries(
  MOVEMENT_OPTIONS.map((o) => [o.uiKey, o]),
) as Record<string, MovementOption>

// ── Props ──────────────────────────────────────────────────────────────────────

interface StockAdjustmentModalProps {
  open:         boolean
  onOpenChange: (open: boolean) => void
  /** Pre-selected product. If undefined a product dropdown is shown. */
  product?:     Product
  /** Called after a successful adjustment. */
  onSuccess?:   () => void
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

  // ── Form state ──────────────────────────────────────────────────────────────
  const [selectedProductId, setSelectedProductId] = useState<string>(
    propProduct?.id ?? "",
  )
  const [movementKey, setMovementKey] = useState<string>("adjustment_in")
  const [quantity, setQuantity]       = useState<string>("")
  const [reason, setReason]           = useState<string>("")
  const [notes, setNotes]             = useState<string>("")
  const [loading, setLoading]         = useState(false)

  // ── Derived helpers ─────────────────────────────────────────────────────────
  const option = OPTION_BY_KEY[movementKey] ?? MOVEMENT_OPTIONS[0]

  const activeProduct: Product | undefined = useMemo(() => {
    if (propProduct) return propProduct
    return products.find((p) => p.id === selectedProductId)
  }, [propProduct, products, selectedProductId])

  // Only trackable, non-parent products can be adjusted
  const adjustableProducts = useMemo(
    () =>
      products.filter(
        (p) =>
          p.stockControlType !== "variant_only" &&
          p.stockControlType !== "untracked",
      ),
    [products],
  )

  const isPhysicalCount = option.sign === 0

  // Compute preview delta
  const parsedQty = parseFloat(quantity)
  const computedDelta: number | null = useMemo(() => {
    if (isNaN(parsedQty) || parsedQty < 0) return null
    if (isPhysicalCount) {
      if (!activeProduct) return null
      return parsedQty - activeProduct.stock
    }
    return parsedQty * option.sign
  }, [parsedQty, isPhysicalCount, activeProduct, option.sign])

  // ── Reset form ──────────────────────────────────────────────────────────────
  const resetForm = useCallback(() => {
    setSelectedProductId(propProduct?.id ?? "")
    setMovementKey("adjustment_in")
    setQuantity("")
    setReason("")
    setNotes("")
  }, [propProduct?.id])

  // ── Submit ──────────────────────────────────────────────────────────────────
  const handleSubmit = useCallback(async () => {
    if (!activeProduct) {
      toast.error("Seleccioná un producto")
      return
    }
    if (quantity === "" || isNaN(parsedQty) || parsedQty <= 0) {
      toast.error("Ingresá una cantidad válida mayor a cero")
      return
    }
    if (computedDelta === null) return

    // For physical_count: allow delta = 0 only if the stock is already correct
    // (we still call the RPC so it records the count; but the RPC rejects delta=0)
    if (computedDelta === 0) {
      toast.info("El stock ya está en esa cantidad. No hay ajuste que registrar.")
      return
    }

    setLoading(true)
    try {
      const { error } = await supabase.rpc("rpc_stock_adjustment", {
        p_product_id:     activeProduct.id,
        p_quantity_delta: computedDelta,
        p_type:           option.type,
        p_reason:         reason.trim() || null,
        p_notes:          notes.trim()  || null,
      })

      if (error) throw error

      toast.success(
        `Stock de "${activeProduct.name}" actualizado: ` +
        `${computedDelta > 0 ? "+" : ""}${computedDelta} unidades`,
      )

      await refreshData()
      resetForm()
      onOpenChange(false)
      onSuccess?.()
    } catch (err: any) {
      const msg: string = err?.message ?? "Error desconocido"
      if (msg.includes("Stock insuficiente")) {
        toast.error(msg)
      } else {
        toast.error("No se pudo registrar el ajuste. " + msg)
      }
    } finally {
      setLoading(false)
    }
  }, [
    activeProduct, quantity, parsedQty, computedDelta,
    option, reason, notes, supabase, refreshData, resetForm, onOpenChange, onSuccess,
  ])

  // ── Render ──────────────────────────────────────────────────────────────────
  return (
    <Dialog
      open={open}
      onOpenChange={(v) => {
        if (!v) resetForm()
        onOpenChange(v)
      }}
    >
      <DialogContent className="bg-card border-border sm:max-w-[480px]">
        <DialogHeader>
          <DialogTitle className="text-card-foreground text-base font-semibold">
            Ajuste de inventario
          </DialogTitle>
          <DialogDescription className="text-muted-foreground text-sm">
            Registrá un movimiento manual de stock con trazabilidad completa.
          </DialogDescription>
        </DialogHeader>

        <div className="flex flex-col gap-4 pt-1">

          {/* ── Product selector (only when no prop product) ── */}
          {!propProduct && (
            <div className="flex flex-col gap-1.5">
              <Label className="text-xs font-medium text-muted-foreground uppercase tracking-wide">
                Producto
              </Label>
              <Select
                value={selectedProductId}
                onValueChange={setSelectedProductId}
              >
                <SelectTrigger className="bg-background border-border text-foreground">
                  <SelectValue placeholder="Seleccioná un producto…" />
                </SelectTrigger>
                <SelectContent className="bg-card border-border max-h-64 overflow-y-auto">
                  {adjustableProducts.map((p) => (
                    <SelectItem key={p.id} value={p.id}>
                      <span className="font-medium">{p.name}</span>
                      <span className="text-muted-foreground ml-2 text-xs">
                        Stock: {p.stock}
                      </span>
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
            </div>
          )}

          {/* ── Product info chip (when pre-selected) ── */}
          {propProduct && (
            <div className="flex items-center gap-3 rounded-lg border border-border bg-muted/40 px-3 py-2">
              <div className="min-w-0 flex-1">
                <p className="text-sm font-medium text-foreground truncate">
                  {propProduct.name}
                </p>
                <p className="text-xs text-muted-foreground">
                  Stock actual: <span className="font-medium tabular-nums">{propProduct.stock}</span>
                </p>
              </div>
            </div>
          )}

          {/* ── Movement type ── */}
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

            {/* Selected type badge */}
            <div className={cn(
              "flex items-center gap-2 px-3 py-1.5 rounded-md border text-xs font-medium",
              option.bg, option.color,
            )}>
              {option.icon}
              <span>{option.description}</span>
            </div>
          </div>

          {/* ── Quantity ── */}
          <div className="flex flex-col gap-1.5">
            <Label
              htmlFor="adj-quantity"
              className="text-xs font-medium text-muted-foreground uppercase tracking-wide"
            >
              {isPhysicalCount ? "Nueva cantidad en stock" : "Cantidad"}
            </Label>
            <Input
              id="adj-quantity"
              type="number"
              min={0}
              step="any"
              placeholder={isPhysicalCount ? "Cantidad total contada…" : "Ej: 10"}
              value={quantity}
              onChange={(e) => setQuantity(e.target.value)}
              className="bg-background border-border text-foreground"
            />
            {/* Delta preview */}
            {activeProduct && quantity !== "" && computedDelta !== null && (
              <p className="text-xs text-muted-foreground">
                {isPhysicalCount
                  ? `Stock actual: ${activeProduct.stock} → `
                  : "Resultado: "
                }
                <span className={cn(
                  "font-medium tabular-nums",
                  computedDelta > 0 ? "text-emerald-400" : computedDelta < 0 ? "text-red-400" : "text-muted-foreground",
                )}>
                  {computedDelta > 0 ? "+" : ""}{computedDelta}
                </span>
                {" "}→ nuevo stock:{" "}
                <span className="font-medium tabular-nums">
                  {(activeProduct.stock + computedDelta).toFixed(
                    Number.isInteger(activeProduct.stock + computedDelta) ? 0 : 2,
                  )}
                </span>
              </p>
            )}
          </div>

          {/* ── Reason ── */}
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

          {/* ── Notes ── */}
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
              className="bg-background border-border text-foreground resize-none min-h-[64px]"
            />
          </div>

          {/* ── Actions ── */}
          <div className="flex items-center justify-end gap-2 pt-1 border-t border-border">
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
              disabled={loading || !activeProduct || quantity === ""}
            >
              {loading ? (
                <><Loader2 className="h-3.5 w-3.5 mr-1.5 animate-spin" />Guardando…</>
              ) : (
                "Registrar ajuste"
              )}
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  )
}
