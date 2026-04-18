"use client"

import { Trash2 } from "lucide-react"
import { Button } from "@/components/ui/button"
import { NumericInput } from "@/components/ui/numeric-input"
import { formatMoney, type Currency } from "@/lib/format"

// ─── Public types ─────────────────────────────────────────────────────────────

export interface CartDisplayItem {
  id: string
  productName: string
  quantity: number
  /** Unit price (sales) or unit cost (purchases). */
  unitValue: number
  subtotal: number
  /** Optional badge text, e.g. "10% desc." */
  badge?: string
}

interface CartItemListProps {
  items: CartDisplayItem[]
  onRemove: (id: string) => void
  onUpdateQty: (id: string, qty: number) => void
  /** Label shown below the product name. Default: "Precio unit." */
  unitLabel?: string
  currency?: Currency
  /** Maximum allowed quantity per item id. */
  maxQtyMap?: Record<string, number>
}

// ─── Component ────────────────────────────────────────────────────────────────

export function CartItemList({
  items,
  onRemove,
  onUpdateQty,
  unitLabel = "Precio unit.",
  currency = "ARS",
  maxQtyMap,
}: CartItemListProps) {
  if (items.length === 0) return null

  return (
    <div className="flex flex-col rounded-lg border border-border overflow-hidden">
      {/* Column header */}
      <div className="grid grid-cols-[1fr_76px_88px_36px] gap-2 px-3 py-2 bg-accent/40 border-b border-border text-[10px] uppercase tracking-wider text-muted-foreground font-semibold">
        <span>Producto</span>
        <span className="text-center">Cant.</span>
        <span className="text-right">Subtotal</span>
        <span />
      </div>

      {/* Item rows */}
      {items.map((item, idx) => (
        <div
          key={item.id}
          className={[
            "grid grid-cols-[1fr_76px_88px_36px] gap-2 px-3 py-2.5 items-center",
            idx > 0 ? "border-t border-border/50" : "",
            "transition-colors hover:bg-accent/20",
          ].join(" ")}
        >
          {/* Product info */}
          <div className="flex flex-col gap-0.5 min-w-0">
            <span className="text-sm font-medium text-foreground truncate leading-tight">
              {item.productName}
            </span>
            <div className="flex items-center gap-2 flex-wrap">
              <span className="text-[11px] text-muted-foreground">
                {unitLabel}: {formatMoney(item.unitValue, currency)}
              </span>
              {item.badge && (
                <span className="text-[10px] font-semibold px-1.5 py-0.5 rounded-full bg-amber-500/15 text-amber-400 border border-amber-500/25">
                  {item.badge}
                </span>
              )}
            </div>
          </div>

          {/* Quantity editor */}
          <NumericInput
            min={1}
            max={maxQtyMap?.[item.id]}
            value={item.quantity}
            onValueChange={(val) => onUpdateQty(item.id, val)}
            className="bg-background border-border text-foreground text-sm h-8"
          />

          {/* Subtotal */}
          <div className="text-right text-sm font-bold text-primary tabular-nums">
            {formatMoney(item.subtotal, currency)}
          </div>

          {/* Remove */}
          <Button
            type="button"
            variant="ghost"
            size="icon"
            className="h-8 w-8 shrink-0 text-muted-foreground hover:text-destructive hover:bg-destructive/10 transition-colors"
            onClick={() => onRemove(item.id)}
            aria-label={`Eliminar ${item.productName}`}
          >
            <Trash2 className="h-3.5 w-3.5" />
          </Button>
        </div>
      ))}
    </div>
  )
}
