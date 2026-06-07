"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── Types ─────────────────────────────────────────────────────────────────────

export interface Organization {
  id: string
  name: string | null
  created_at: string | null
}

export interface OrgSettingsUpdate {
  name?: string
}

// ── Query ─────────────────────────────────────────────────────────────────────

/**
 * Fetches a single organization by ID from the Python API.
 */
export function useOrganization(orgId: string | null | undefined) {
  const query = useQuery({
    queryKey: queryKeys.organizations.detail(orgId ?? ""),
    queryFn: async (): Promise<Organization> => {
      return pythonClient.get<Organization>(`/organizations/${orgId}`)
    },
    enabled: !!orgId,
    staleTime: 5 * 60 * 1000, // 5 min — org settings rarely change
  })

  return {
    organization: query.data ?? null,
    isLoading: query.isLoading,
    isError: query.isError,
    error: query.error,
  }
}

// ── Mutations ─────────────────────────────────────────────────────────────────

/**
 * Mutation to update organization settings (name, etc.) via Python API.
 */
export function useUpdateOrganization() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({
      orgId,
      payload,
    }: {
      orgId: string
      payload: OrgSettingsUpdate
    }): Promise<Organization> => {
      return pythonClient.put<Organization>(`/organizations/${orgId}/settings`, payload)
    },
    onSuccess: (_data, { orgId }) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.organizations.detail(orgId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.organizations.all() })
    },
  })
}
