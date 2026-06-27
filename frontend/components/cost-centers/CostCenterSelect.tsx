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
}

/**
 * Dropdown to optionally assign a cost center to an expense or purchase.
 *
 * Shows only active cost centers (is_active=true) so deactivated centers
 * don't appear in new-entry forms (they still appear in historical records).
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
}: CostCenterSelectProps) {
  // active_only=true (default) — only show active centers for new entries
  const { costCenters, isLoading } = useCostCenters(false)

  return (
    <div className="flex flex-col gap-2">
      {showLabel && (
        <Label className="text-foreground text-sm">
          Centro de costo <span className="text-muted-foreground font-normal">(opcional)</span>
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
            </SelectItem>
          ))}
        </SelectContent>
      </Select>
    </div>
  )
}
