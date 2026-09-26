"use client"

/**
 * punto-venta-seleccion (D7) — selector ÚNICO de punto de venta.
 *
 * Lo consumen el diálogo de emisión de ventas (`EmitirComprobanteDialog`, en
 * /ventas y /ventas/ordenes) y el de suscripciones (`EmitirSuscripcionDialog`,
 * /admin/pagos). Antes cada diálogo tenía su copia del <Select>.
 *
 *   - Sin PV activos → no renderiza nada (cada contenedor muestra su aviso).
 *   - Un solo activo → lo muestra como texto ("Único PV activo"): no hay nada
 *     que elegir.
 *   - Varios → <Select> con etiqueta asociada, sólo activos, y el badge
 *     "Predeterminado" en el que corresponde.
 *
 * Controlado: el valor inicial (la preselección de
 * `resolvePreselectedPointOfSale`) lo decide el contenedor.
 */

import { useId } from "react"

import { Badge } from "@/components/ui/badge"
import { Label } from "@/components/ui/label"
import {
  Select,
  SelectContent,
  SelectItem,
  SelectTrigger,
  SelectValue,
} from "@/components/ui/select"
import { activePointsOfSale, formatPointOfSaleLabel } from "@/lib/fiscal-point-of-sale"
import type { PointOfSale } from "@/hooks/data/use-points-of-sale"

interface PointOfSaleSelectProps {
  pointsOfSale: PointOfSale[]
  /** Id del PV elegido ("" = ninguno). */
  value: string
  onValueChange: (pointOfSaleId: string) => void
  /** Id del trigger (para enlazar la etiqueta); por defecto uno generado. */
  id?: string
  disabled?: boolean
}

export function PointOfSaleSelect({
  pointsOfSale,
  value,
  onValueChange,
  id,
  disabled,
}: PointOfSaleSelectProps) {
  const generatedId = useId()
  const triggerId = id ?? generatedId
  const active = activePointsOfSale(pointsOfSale)

  if (active.length === 0) return null

  if (active.length === 1) {
    const only = active[0]
    return (
      <div className="rounded-md border border-border bg-muted/30 p-3 text-sm">
        <div className="flex items-center justify-between gap-2">
          <span className="text-muted-foreground">Punto de venta</span>
          <span className="font-semibold text-foreground tabular-nums">
            {formatPointOfSaleLabel(only.numero)}
          </span>
        </div>
        <p className="mt-1 text-xs text-muted-foreground">
          Único PV activo — seleccionado automáticamente.
        </p>
      </div>
    )
  }

  return (
    <div className="flex flex-col gap-1.5">
      <Label htmlFor={triggerId}>Punto de venta</Label>
      <Select value={value} onValueChange={onValueChange} disabled={disabled}>
        <SelectTrigger id={triggerId} className="border-border bg-background text-foreground">
          <SelectValue placeholder="Elegí un punto de venta" />
        </SelectTrigger>
        <SelectContent className="border-border bg-popover">
          {active.map((pv) => (
            <SelectItem key={pv.id} value={pv.id}>
              <span className="flex items-center gap-2 tabular-nums">
                {formatPointOfSaleLabel(pv.numero)}
                {pv.isDefault && (
                  <Badge variant="secondary" className="px-1.5 py-0 text-[11px] font-medium">
                    Predeterminado
                  </Badge>
                )}
              </span>
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}
