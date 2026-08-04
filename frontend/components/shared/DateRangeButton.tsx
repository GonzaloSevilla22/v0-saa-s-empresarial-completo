"use client"

import { format, isAfter, isBefore } from "date-fns"
import { Button } from "@/components/ui/button"
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover"
import { Calendar } from "@/components/ui/calendar"
import { CalendarIcon } from "lucide-react"

/**
 * Botón de fecha con popover de calendario para los rangos de los reportes.
 *
 * Vivía embebido en /reportes/sucursal; se extrajo acá cuando el reporte por
 * centro de costo necesitó el mismo control (cost-center-surface), en vez de
 * copiarlo.
 */
export function DateButton({
  date,
  onSelect,
  minDate,
  maxDate,
  label,
}: {
  date: Date
  onSelect: (d: Date) => void
  minDate?: Date
  maxDate?: Date
  /** Texto accesible del botón (el visible es la fecha). */
  label?: string
}) {
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="outline" size="sm" className="text-xs" aria-label={label}>
          <CalendarIcon className="h-3 w-3 mr-1" />
          {format(date, "dd/MM/yyyy")}
        </Button>
      </PopoverTrigger>
      <PopoverContent className="w-auto p-0" align="start">
        <Calendar
          mode="single"
          selected={date}
          onSelect={(d) => d && onSelect(d)}
          disabled={(d) =>
            (minDate ? isBefore(d, minDate) : false) ||
            (maxDate ? isAfter(d, maxDate) : false)
          }
          initialFocus
        />
      </PopoverContent>
    </Popover>
  )
}

/** ISO corto (yyyy-MM-dd) para los parámetros DATE de los RPCs de reporting. */
export function toISODate(d: Date): string {
  return format(d, "yyyy-MM-dd")
}
