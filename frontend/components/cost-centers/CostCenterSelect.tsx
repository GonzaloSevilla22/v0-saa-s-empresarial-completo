"use client"

import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { Label } from "@/components/ui/label"
import { useCostCenters } from "@/hooks/data/use-cost-centers"

interface CostCenterSelectProps {
  value: string | null
  onChange: (value: string | null) => void
  placeholder?: string
  className?: string
  /** Label shown above the select. Pass false to hide (default: shown). */
  showLabel?: boolean
  /** Text of the label when shown (default: the new-entry wording). */
  label?: string
  /**
   * cost-center-surface: include deactivated centers in the options.
   *
   * false (default) for NEW entries — a center that was given up shouldn't be
   * imputable. true when filtering existing records, where the history of a
   * deactivated center still has to be reachable.
   */
  includeInactive?: boolean
}

/**
 * Dropdown to pick a cost center — used both to assign one to a new expense or
 * purchase and to filter the expense/purchase lists.
 *
 * Renders a plain label+select — no plan-gating since the cost center catalog
 * is available on all plans (additive dimension, not a gated module).
 */
export function CostCenterSelect({
  value,
  onChange,
  placeholder = "Sin centro de costo",
  className,
  showLabel = true,
  label,
  includeInactive = false,
}: CostCenterSelectProps) {
  const { costCenters, isLoading } = useCostCenters(includeInactive)

  return (
    <div className="flex flex-col gap-2">
      {showLabel && (
        <Label className="text-foreground text-sm">
          {label ?? (
            <>
              Centro de costo <span className="text-muted-foreground font-normal">(opcional)</span>
            </>
          )}
        </Label>
      )}
      <Select
        value={value ?? "__none__"}
        onValueChange={(v) => onChange(v === "__none__" ? null : v)}
        disabled={isLoading}
      >
        <SelectTrigger className={className ?? "bg-background border-border text-foreground"}>
          <SelectValue placeholder={placeholder} />
        </SelectTrigger>
        <SelectContent>
          <SelectItem value="__none__">{placeholder}</SelectItem>
          {costCenters.map((cc) => (
            <SelectItem key={cc.id} value={cc.id}>
              {cc.code ? `${cc.code} — ${cc.name}` : cc.name}
              {!cc.isActive && " (inactivo)"}
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}
