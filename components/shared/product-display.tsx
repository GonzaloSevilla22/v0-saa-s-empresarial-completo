"use client"

import { cn } from "@/lib/utils"
import type { Currency } from "@/lib/format"
import { formatPricePerUnit, formatStock } from "@/lib/format-unit"

// ── Data contract ─────────────────────────────────────────────────────────────

/**
 * Structured product data passed via SearchableSelect's `data` field.
 * Keeps the combobox option typed — no more pre-formatted sublabel strings.
 */
export interface ProductOptionData {
  name: string
  parentName?: string
  price: number
  stock: number
  unitSymbol?: string
}

// ── Props ─────────────────────────────────────────────────────────────────────

interface ProductDisplayProps {
  name: string
  parentName?: string
  price?: number
  stock?: number
  unitSymbol?: string
  currency?: Currency
  /**
   * option — two-line row inside a combobox dropdown.
   *          Parent name on top (muted), variant name below (bold).
   *          Price and stock aligned to the right.
   *
   * cart   — compact column in the cart grid.
   *          Variant name on top, parent name below (muted).
   *          No price (shown separately by CartItemList).
   */
  mode: "option" | "cart"
  className?: string
}

// ── Component ─────────────────────────────────────────────────────────────────

export function ProductDisplay({
  name,
  parentName,
  price,
  stock,
  unitSymbol,
  currency,
  mode,
  className,
}: ProductDisplayProps) {
  // ── option mode ─────────────────────────────────────────────────────────────
  if (mode === "option") {
    return (
      <div className={cn("flex items-center justify-between min-w-0 flex-1 gap-3", className)}>
        {/* Left: parent (muted) + variant name */}
        <div className="flex flex-col min-w-0">
          {parentName && (
            <span className="text-[10px] leading-none text-muted-foreground truncate mb-0.5">
              {parentName}
            </span>
          )}
          <span className="text-sm font-medium text-foreground truncate leading-tight">
            {name}
          </span>
        </div>

        {/* Right: price + stock indicator */}
        {(price !== undefined || stock !== undefined) && (
          <div className="flex flex-col items-end shrink-0 gap-0.5">
            {price !== undefined && (
              <span className="text-[10px] text-muted-foreground tabular-nums leading-none">
                {formatPricePerUnit(price, unitSymbol, currency)}
              </span>
            )}
            {stock !== undefined && (
              <span
                className={cn(
                  "text-[10px] tabular-nums leading-none",
                  stock <= 0
                    ? "text-red-400"
                    : stock <= 5
                    ? "text-amber-400"
                    : "text-muted-foreground",
                )}
              >
                {formatStock(stock, unitSymbol)}
              </span>
            )}
          </div>
        )}
      </div>
    )
  }

  // ── cart mode ────────────────────────────────────────────────────────────────
  return (
    <div className={cn("flex flex-col min-w-0", className)}>
      <span className="text-sm font-medium text-foreground truncate leading-tight">
        {name}
      </span>
      {parentName && (
        <span className="text-[10px] text-muted-foreground truncate leading-none mt-0.5">
          {parentName}
        </span>
      )}
    </div>
  )
}
