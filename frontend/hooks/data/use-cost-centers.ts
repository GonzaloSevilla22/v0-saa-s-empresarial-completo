"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { CostCenter } from "@/lib/types"

// ── Types for API responses ───────────────────────────────────────────────────

interface CostCenterApiRow {
  id: string
  account_id: string
  name: string
  code: string | null
  is_active: boolean
  created_at: string
}

function mapCostCenter(r: CostCenterApiRow): CostCenter {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    code:      r.code,
    isActive:  r.is_active,
    createdAt: r.created_at,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Returns cost centers list + mutations (create, update, deactivate).
 *
 * @param includeInactive - When true, fetches all centers including deactivated
 *   ones (used in the management screen for owner/admin). Default false.
 */
export function useCostCenters(includeInactive = false) {
  const queryClient = useQueryClient()

  // Use different query keys so active-only and all-inclusive caches don't collide
  const queryKey = includeInactive
    ? queryKeys.costCenters.lists()
    : queryKeys.costCenters.active()

  const query = useQuery({
    queryKey,
    queryFn: async (): Promise<CostCenter[]> => {
      const url = includeInactive
        ? "/cost-centers?include_inactive=true"
        : "/cost-centers"
      const data = await pythonClient.get<CostCenterApiRow[]>(url)
      return data.map(mapCostCenter)
    },
    staleTime: 5 * 60 * 1000, // 5 min — catalog changes infrequently
  })

  const createCostCenterMutation = useMutation({
    mutationFn: async (payload: { name: string; code?: string | null }) => {
      return pythonClient.post<CostCenterApiRow>("/cost-centers", payload)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.costCenters.all() })
    },
  })

  const updateCostCenterMutation = useMutation({
    mutationFn: async ({
      id,
      name,
      code,
    }: {
      id: string
      name: string
      code?: string | null
    }) => {
      return pythonClient.patch<CostCenterApiRow>(`/cost-centers/${id}`, { name, code })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.costCenters.all() })
    },
  })

  const deactivateCostCenterMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.patch<CostCenterApiRow>(`/cost-centers/${id}/deactivate`, {})
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.costCenters.all() })
    },
  })

  return {
    costCenters:    query.data ?? [],
    isLoading:      query.isLoading,
    isError:        query.isError,
    error:          query.error,
    createCostCenter:    createCostCenterMutation.mutateAsync,
    updateCostCenter:    updateCostCenterMutation.mutateAsync,
    deactivateCostCenter: deactivateCostCenterMutation.mutateAsync,
    // Individual mutation states for UI feedback
    createCostCenterMutation,
    updateCostCenterMutation,
    deactivateCostCenterMutation,
  }
}
