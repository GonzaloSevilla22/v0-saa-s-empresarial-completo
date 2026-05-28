"use client"

import { cn } from "@/lib/utils"
import type { Currency } from "@/lib/format"
import { formatPricePerUnit, formatStock } from "@/lib/format-unit"
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip"

// ── Data contract ─────────────────────────────────────────────────────────────

/**
 * Structured product data passed via SearchableSelect's `data` field
 * or ProductPicker internally. Replaces pre-formatted sublabel strings.
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
   * option   — two-line dropdown row. Parent (muted) above, variant (bold) below.
   *            Price and stock right-aligned, stock color-coded by level.
   *
   * trigger  — selected state inside the combobox button. Two lines when
   *            parent is present; single line for standalone products.
   *
   * cart     — compact column in the cart grid. Variant on top, parent (muted)
   *            below. Price shown separately by CartItemList.
   *
   * table    — single truncated line in a data table. Tooltip reveals the full
   *            canonical label (parent / variant) on hover.
   */
  mode: "option" | "trigger" | "cart" | "table"
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
  // ── option ───────────────────────────────────────────────────────────────────
  if (mode === "option") {
    return (
      <div className={cn("flex items-center justify-between min-w-0 flex-1 gap-3", className)}>
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
                  stock <= 0 ? "text-red-400" : stock <= 5 ? "text-amber-400" : "text-muted-foreground",
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

  // ── trigger ──────────────────────────────────────────────────────────────────
  if (mode === "trigger") {
    return (
      <div className={cn("flex flex-col min-w-0 text-left", className)}>
        <span className="text-sm font-medium truncate leading-tight">
          {name}
        </span>
        {parentName && (
          <span className="text-xs text-muted-foreground truncate leading-none mt-0.5">
            {parentName}
          </span>
        )}
      </div>
    )
  }

  // ── table ────────────────────────────────────────────────────────────────────
  if (mode === "table") {
    const fullLabel = parentName ? `${parentName} / ${name}` : name
    return (
      <TooltipProvider>
        <Tooltip delayDuration={600}>
          <TooltipTrigger asChild>
            <span className={cn("font-medium text-foreground truncate block cursor-default", className)}>
              {name}
            </span>
          </TooltipTrigger>
          {parentName && (
            <TooltipContent side="top" className="max-w-xs">
              <p className="text-xs">{fullLabel}</p>
            </TooltipContent>
          )}
        </Tooltip>
      </TooltipProvider>
    )
  }

  // ── cart ─────────────────────────────────────────────────────────────────────
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
