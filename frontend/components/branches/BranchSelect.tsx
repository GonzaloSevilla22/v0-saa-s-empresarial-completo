"use client"

import {
  Select, SelectContent, SelectItem, SelectTrigger, SelectValue,
} from "@/components/ui/select"
import { useBranches } from "@/hooks/data/use-branches"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"

interface BranchSelectProps {
  value: string | null
  onChange: (value: string | null) => void
  placeholder?: string
  className?: string
  /**
   * remitos-venta (D11): la sucursal es obligatoria. Sin la opción "Sin
   * sucursal" (`onChange` nunca recibe `null`) y sin las sucursales CERRADAS
   * (`status = 'closed'`, que el servidor rechaza con `branch_closed`). El
   * placeholder por defecto pasa a "Elegí la sucursal". Default `false`: los
   * usos actuales no cambian.
   */
  required?: boolean
  /**
   * remitos-venta (D11): se muestra aunque el plan no tenga módulo de
   * sucursales (3 de los 4 planes) — el remito sale siempre de una sucursal
   * concreta. Default `false`: los usos actuales no cambian.
   */
  alwaysVisible?: boolean
}

/**
 * Dropdown to select a branch for an operation.
 * Renders nothing if the account plan has no branches module (non-PRO), salvo
 * con `alwaysVisible`.
 */
export function BranchSelect({
  value,
  onChange,
  placeholder,
  className,
  required = false,
  alwaysVisible = false,
}: BranchSelectProps) {
  const { limits } = usePlanLimits()
  const { branches } = useBranches()

  if (!alwaysVisible && !limits?.hasBranchesModule) return null

  const effectivePlaceholder = placeholder ?? (required ? "Elegí la sucursal" : "Sin sucursal (general)")

  if (required) {
    return (
      <Select value={value ?? ""} onValueChange={(v) => onChange(v)}>
        <SelectTrigger className={className}>
          <SelectValue placeholder={effectivePlaceholder} />
        </SelectTrigger>
        <SelectContent>
          {branches
            .filter((branch) => branch.status !== "closed")
            .map((branch) => (
              <SelectItem key={branch.id} value={branch.id}>
                {branch.name}
              </SelectItem>
            ))}
        </SelectContent>
      </Select>
    )
  }

  return (
    <Select
      value={value ?? "__none__"}
      onValueChange={(v) => onChange(v === "__none__" ? null : v)}
    >
      <SelectTrigger className={className}>
        <SelectValue placeholder={effectivePlaceholder} />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="__none__">{effectivePlaceholder}</SelectItem>
        {branches.map((branch) => (
          <SelectItem key={branch.id} value={branch.id}>
            {branch.name}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
