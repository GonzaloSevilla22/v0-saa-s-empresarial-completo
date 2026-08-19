"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { PaymentMethod, PaymentMethodKind } from "@/lib/types"

// ── Types for API responses ───────────────────────────────────────────────────

interface PaymentMethodApiRow {
  id: string
  account_id: string
  name: string
  kind: PaymentMethodKind
  is_active: boolean
  sort_order: number
  created_at: string
}

function mapPaymentMethod(r: PaymentMethodApiRow): PaymentMethod {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    kind:      r.kind,
    isActive:  r.is_active,
    sortOrder: r.sort_order,
    createdAt: r.created_at,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Returns payment methods list + mutations (create, update, deactivate).
 * Espejo de useCostCenters (metodos-pago-operaciones).
 *
 * @param includeInactive - When true, fetches all methods including deactivated
 *   ones (used in the management screen for owner/admin). Default false.
 */
export function usePaymentMethods(includeInactive = false) {
  const queryClient = useQueryClient()

  const queryKey = includeInactive
    ? queryKeys.paymentMethods.lists()
    : queryKeys.paymentMethods.active()

  const query = useQuery({
    queryKey,
    queryFn: async (): Promise<PaymentMethod[]> => {
      const url = includeInactive
        ? "/payment-methods?include_inactive=true"
        : "/payment-methods"
      const data = await pythonClient.get<PaymentMethodApiRow[]>(url)
      return data.map(mapPaymentMethod)
    },
    staleTime: 5 * 60 * 1000, // 5 min — catalog changes infrequently
  })

  const createPaymentMethodMutation = useMutation({
    mutationFn: async (payload: { name: string; kind: PaymentMethodKind; sortOrder?: number }) => {
      return pythonClient.post<PaymentMethodApiRow>("/payment-methods", {
        name: payload.name,
        kind: payload.kind,
        sort_order: payload.sortOrder ?? 0,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.paymentMethods.all() })
    },
  })

  const updatePaymentMethodMutation = useMutation({
    mutationFn: async ({
      id,
      name,
      sortOrder,
    }: {
      id: string
      name: string
      sortOrder?: number | null
    }) => {
      return pythonClient.patch<PaymentMethodApiRow>(`/payment-methods/${id}`, {
        name,
        sort_order: sortOrder ?? null,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.paymentMethods.all() })
    },
  })

  const deactivatePaymentMethodMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.patch<PaymentMethodApiRow>(`/payment-methods/${id}/deactivate`, {})
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.paymentMethods.all() })
    },
  })

  return {
    paymentMethods: query.data ?? [],
    isLoading:      query.isLoading,
    isError:        query.isError,
    error:          query.error,
    createPaymentMethod:    createPaymentMethodMutation.mutateAsync,
    updatePaymentMethod:    updatePaymentMethodMutation.mutateAsync,
    deactivatePaymentMethod: deactivatePaymentMethodMutation.mutateAsync,
    createPaymentMethodMutation,
    updatePaymentMethodMutation,
    deactivatePaymentMethodMutation,
  }
}
