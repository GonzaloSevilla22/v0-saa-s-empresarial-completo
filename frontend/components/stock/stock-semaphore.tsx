"use client"

import { cn } from "@/lib/utils"
import { getStockStatus, type StockStatus } from "@/lib/product-stock"

interface StockSemaphoreProps {
  stock: number
  minStock: number
  size?: "sm" | "md"
}

/**
 * Visual style per stock status. `sin-umbral` (no minimum configured) renders a
 * muted, neutral dot — never red — matching the canonical DB rule that excludes
 * products with no threshold from every alert and KPI (see getStockStatus).
 */
const STATUS_STYLE: Record<StockStatus, { label: string; dot: string; text: string }> = {
  critico: {
    label: "Crítico",
    dot:   "bg-red-500 shadow-[0_0_6px_rgba(239,68,68,0.5)]",
    text:  "text-red-400",
  },
  bajo: {
    label: "Bajo",
    dot:   "bg-yellow-500 shadow-[0_0_6px_rgba(234,179,8,0.5)]",
    text:  "text-yellow-400",
  },
  ok: {
    label: "OK",
    dot:   "bg-emerald-500 shadow-[0_0_6px_rgba(16,185,129,0.5)]",
    text:  "text-emerald-400",
  },
  "sin-umbral": {
    label: "Sin mínimo",
    dot:   "bg-muted-foreground/40",
    text:  "text-muted-foreground",
  },
}

export function StockSemaphore({ stock, minStock, size = "md" }: StockSemaphoreProps) {
  const s = STATUS_STYLE[getStockStatus(stock, minStock)]
  const sizeClass = size === "sm" ? "h-2.5 w-2.5" : "h-3.5 w-3.5"

  return (
    <div className="flex items-center gap-2">
      <div className={cn("rounded-full", sizeClass, s.dot)} />
      <span className={cn("text-xs font-medium", s.text)}>{s.label}</span>
    </div>
  )
}
