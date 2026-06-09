"use client"

import { useRouter, useSearchParams } from "next/navigation"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { monthKey, parseMonthKey } from "@/lib/date-range"

/**
 * Selector de período del Tablero (?period=YYYY-MM, patrón de BranchFilter).
 * Mes en curso por defecto; afecta al Bloque Resumen KPI. v1: mes en curso /
 * mes anterior (extensible a histórico luego).
 */
export function PeriodFilter() {
  const router = useRouter()
  const searchParams = useSearchParams()

  const now = new Date()
  const currKey = monthKey(now)
  const prevKey = monthKey(new Date(now.getFullYear(), now.getMonth() - 1, 1))

  // parseMonthKey cae al mes actual ante valores inválidos/desconocidos.
  const selected = monthKey(parseMonthKey(searchParams.get("period")))
  const value = selected === prevKey ? prevKey : currKey

  function handleChange(next: string) {
    const params = new URLSearchParams(searchParams.toString())
    if (next === currKey) {
      params.delete("period") // mes en curso = default, URL limpia
    } else {
      params.set("period", next)
    }
    router.push(`?${params.toString()}`)
  }

  return (
    <Select value={value} onValueChange={handleChange}>
      <SelectTrigger className="w-40 bg-background border-border text-foreground text-sm h-9">
        <SelectValue placeholder="Período" />
      </SelectTrigger>
      <SelectContent className="bg-popover border-border">
        <SelectItem value={currKey}>Mes en curso</SelectItem>
        <SelectItem value={prevKey}>Mes anterior</SelectItem>
      </SelectContent>
    </Select>
  )
}
