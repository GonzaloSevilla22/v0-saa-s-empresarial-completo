"use client"

import { cn } from "@/lib/utils"

interface StockSemaphoreProps {
  stock: number
  minStock: number
  size?: "sm" | "md"
}

export function StockSemaphore({ stock, minStock, size = "md" }: StockSemaphoreProps) {
  const isRed = stock <= minStock
  const isYellow = !isRed && stock <= minStock * 1.5
  const isGreen = !isRed && !isYellow

  const sizeClass = size === "sm" ? "h-2.5 w-2.5" : "h-3.5 w-3.5"

  return (
    <div className="flex items-center gap-2">
      <div
        className={cn(
          "rounded-full",
          sizeClass,
          isRed && "bg-red-500 shadow-[0_0_6px_rgba(239,68,68,0.5)]",
          isYellow && "bg-yellow-500 shadow-[0_0_6px_rgba(234,179,8,0.5)]",
          isGreen && "bg-emerald-500 shadow-[0_0_6px_rgba(16,185,129,0.5)]"
        )}
      />
      <span className={cn(
        "text-xs font-medium",
        isRed && "text-red-400",
        isYellow && "text-yellow-400",
        isGreen && "text-emerald-400",
      )}>
        {isRed ? "Critico" : isYellow ? "Bajo" : "OK"}
      </span>
    </div>
  )
}
