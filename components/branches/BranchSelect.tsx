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
}

/**
 * Dropdown to select a branch for an operation.
 * Renders nothing if the account plan has no branches module (non-PRO).
 */
export function BranchSelect({
  value,
  onChange,
  placeholder = "Sin sucursal (general)",
  className,
}: BranchSelectProps) {
  const { limits } = usePlanLimits()
  const { branches } = useBranches()

  if (!limits?.hasBranchesModule) return null

  return (
    <Select
      value={value ?? "__none__"}
      onValueChange={(v) => onChange(v === "__none__" ? null : v)}
    >
      <SelectTrigger className={className}>
        <SelectValue placeholder={placeholder} />
      </SelectTrigger>
      <SelectContent>
        <SelectItem value="__none__">{placeholder}</SelectItem>
        {branches.map((branch) => (
          <SelectItem key={branch.id} value={branch.id}>
            {branch.name}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
