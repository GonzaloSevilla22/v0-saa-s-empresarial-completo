"use client"

import { useMemo } from "react"
import { useQuery } from "@tanstack/react-query"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import type { OrgRole } from "@/lib/types"

interface UseOrgRoleReturn {
  role: OrgRole | null
  isWriter: boolean
  isLoading: boolean
}

/**
 * Returns the current user's role within their active account, and whether
 * they have write access (owner or admin).
 *
 * Uses React Query with a 5-minute stale time to stay fresh after role changes
 * made by other admins without requiring a full re-login.
 */
export function useOrgRole(): UseOrgRoleReturn {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const supabase  = useMemo(() => createClient(), [])

  const { data: role, isLoading } = useQuery<OrgRole | null>({
    queryKey: ["orgRole", accountId],
    queryFn:  async () => {
      if (!accountId) return null
      const { data, error } = await supabase.rpc("rpc_my_account_role", {
        p_account_id: accountId,
      })
      if (error) throw error
      return (data as OrgRole | null) ?? null
    },
    enabled:   !!accountId,
    staleTime: 5 * 60 * 1000,
    initialData: user?.accountRole ?? null,
  })

  const isWriter = role === "owner" || role === "admin"

  return { role: role ?? null, isWriter, isLoading }
}
