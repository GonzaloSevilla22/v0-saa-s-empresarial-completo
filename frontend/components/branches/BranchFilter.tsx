"use client"

import { useEffect } from "react"
import { useRouter, useSearchParams } from "next/navigation"
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select"
import { useBranches } from "@/hooks/data/use-branches"
import { usePlanLimits } from "@/hooks/auth/use-plan-limits"
import type { Branch } from "@/lib/types"

const SESSION_KEY = "eie_branch_filter"

export function BranchFilter() {
  const router        = useRouter()
  const searchParams  = useSearchParams()
  const { limits } = usePlanLimits()
  const { branches } = useBranches()

  const currentBranch = searchParams.get("branch") ?? ""

  // Restore persisted selection on mount
  useEffect(() => {
    if (currentBranch) return
    const stored = sessionStorage.getItem(SESSION_KEY)
    if (stored && branches.some((b: Branch) => b.id === stored)) {
      const params = new URLSearchParams(searchParams.toString())
      params.set("branch", stored)
      router.replace(`?${params.toString()}`)
    }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [branches])

  if (!limits?.hasBranchesModule) return null

  function handleChange(value: string) {
    const params = new URLSearchParams(searchParams.toString())
    if (value === "__all__") {
      params.delete("branch")
      sessionStorage.removeItem(SESSION_KEY)
    } else {
      params.set("branch", value)
      sessionStorage.setItem(SESSION_KEY, value)
    }
    router.push(`?${params.toString()}`)
  }

  return (
    <Select value={currentBranch || "__all__"} onValueChange={handleChange}>
      <SelectTrigger className="w-48 bg-background border-border text-foreground text-sm h-9">
        <SelectValue placeholder="Todas las sucursales" />
      </SelectTrigger>
      <SelectContent className="bg-popover border-border">
        <SelectItem value="__all__">Todas las sucursales</SelectItem>
        {branches.map((branch: Branch) => (
          <SelectItem key={branch.id} value={branch.id}>
            {branch.name}
          </SelectItem>
        ))}
      </SelectContent>
    </Select>
  )
}
