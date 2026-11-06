"use client"

import { useMemo } from "react"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useUnitsOfMeasure } from "@/hooks/use-units-of-measure"

/**
 * ventas-unidades-conversion (decisión 7, OK del PO 2026-09-27): valor del
 * selector para la opción explícita "Sin unidad". Radix no admite un
 * `SelectItem` con `value=""` (el vacío queda reservado para el placeholder
 * "Seleccionar unidad", que significa "no lo toqué"); los ids de unidad son
 * uuid, así que el centinela no colisiona.
 */
export const NO_BASE_UNIT = "none"

const UNIT_TYPE_LABELS: Record<string, string> = {
  unit: "Unidades",
  weight: "Peso",
  volume: "Volumen",
  length: "Longitud",
  custom: "Personalizadas",
}

interface UnitSelectProps {
  value: string
  onChange: (v: string) => void
  /** Ofrece la opción explícita «Sin unidad» (decisión 7). El diálogo «Corregir unidad» no la ofrece: relabel exige una unidad. */
  allowNone?: boolean
  "aria-label"?: string
}

/** Selector de unidad agrupado por tipo (peso, volumen, …): lo comparten el formulario y el diálogo «Corregir unidad». */
export function UnitSelect({ value, onChange, allowNone = true, ...rest }: UnitSelectProps) {
  const { units } = useUnitsOfMeasure()
  const unitGroups = useMemo(() => {
    const groupMap = new Map<string, typeof units>()
    for (const u of units) {
      const arr = groupMap.get(u.type) ?? []
      arr.push(u)
      groupMap.set(u.type, arr)
    }
    return groupMap
  }, [units])

  return (
    <Select value={value} onValueChange={onChange}>
      <SelectTrigger className="bg-background border-border text-foreground" aria-label={rest["aria-label"]}>
        <SelectValue placeholder="Seleccionar unidad" />
      </SelectTrigger>
      <SelectContent className="bg-popover border-border max-h-56">
        {/* Decisión 7: opción explícita para desasignar la unidad base. */}
        {allowNone && <SelectItem value={NO_BASE_UNIT}>Sin unidad</SelectItem>}
        {Array.from(unitGroups.entries()).map(([type, groupUnits]) => (
          <div key={type}>
            <div className="px-2 py-1 text-[10px] font-semibold uppercase tracking-wider text-muted-foreground">
              {UNIT_TYPE_LABELS[type] ?? type}
            </div>
            {groupUnits.map((u) => (
              <SelectItem key={u.id} value={u.id}>
                {u.name} <span className="text-muted-foreground">({u.symbol})</span>
              </SelectItem>
            ))}
          </div>
        ))}
      </SelectContent>
    </Select>
  )
}
