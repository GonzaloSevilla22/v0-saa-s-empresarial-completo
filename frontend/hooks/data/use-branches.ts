"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { queryKeys } from "@/lib/query-keys"
import type { Branch } from "@/lib/types"

function mapRow(r: {
  id: string
  account_id: string
  name: string
  address: string | null
  is_active: boolean
  created_at: string
}): Branch {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    address:   r.address,
    isActive:  r.is_active,
    createdAt: r.created_at,
  }
}

function translateRpcError(message: string): string {
  if (message.includes("branch_limit_exceeded")) return "Límite de sucursales alcanzado para tu plan."
  if (message.includes("branch_name_duplicate")) return "Ya existe una sucursal con ese nombre."
  if (message.includes("unauthorized"))          return "No tenés permisos para realizar esta acción."
  if (message.includes("branch_not_found"))      return "La sucursal no existe."
  return message || "Ocurrió un error inesperado."
}

/**
 * Returns the active branches for the current user's account.
 * Only populated for plan 'pro' (hasBranchesModule); returns [] otherwise.
 */
export function useBranches() {
  const { user } = useAuth()
  const supabase  = useMemo(() => createClient(), [])
  const accountId = user?.accountId ?? null

  const query = useQuery({
    queryKey: queryKeys.branches.active(),
    queryFn: async (): Promise<Branch[]> => {
      if (!accountId) return []
      const { data, error } = await supabase
        .from("branches")
        .select("id, account_id, name, address, is_active, created_at")
        .eq("account_id", accountId)
        .eq("is_active", true)
        .order("created_at", { ascending: true })

      if (error) throw error
      return (data ?? []).map(mapRow)
    },
    enabled: !!accountId,
    staleTime: 5 * 60 * 1000, // 5 min — branches rarely change
  })

  return {
    branches:  query.data ?? [],
    isLoading: query.isLoading,
    isError:   query.isError,
  }
}

/**
 * Mutation to create a new branch via rpc_create_branch.
 */
export function useCreateBranch() {
  const queryClient = useQueryClient()
  const { user }    = useAuth()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async ({ name, address }: { name: string; address?: string }) => {
      const accountId = user?.accountId
      if (!accountId) throw new Error("No active account")

      const { data, error } = await supabase.rpc("rpc_create_branch", {
        p_account_id: accountId,
        p_name:       name,
        p_address:    address ?? null,
      })
      if (error) throw new Error(translateRpcError(error.message))
      return data as Branch
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.branches.all() })
    },
  })
}

/**
 * Mutation to soft-delete a branch via rpc_deactivate_branch.
 */
export function useDeactivateBranch() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (branchId: string) => {
      const { error } = await supabase.rpc("rpc_deactivate_branch", {
        p_branch_id: branchId,
      })
      if (error) throw new Error(translateRpcError(error.message))
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.branches.all() })
    },
  })
}
