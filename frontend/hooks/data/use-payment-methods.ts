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
  // pos-banco-movimientos (D7): ausente en filas sembradas por otros
  // changes que el backend no re-serializó — se degrada a null.
  bank_account_id?: string | null
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
    bankAccountId: r.bank_account_id ?? null,
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
    mutationFn: async (params: {
      id: string
      name: string
      sortOrder?: number | null
      /**
       * pos-banco-movimientos (D7): tri-estado por AUSENCIA de la clave —
       * mismo contrato que paymentMethodId/branchId en use-sales.ts. Omitir
       * el campo conserva el destino vigente; `null` explícito lo
       * desasigna; un uuid lo asigna/reasigna. JSON.stringify omite claves
       * `undefined`, así que "ausente" viaja literalmente ausente y el
       * backend (model_fields_set) distingue "preservar" de "informado".
       */
      bankAccountId?: string | null
    }) => {
      const { id, name, sortOrder, bankAccountId } = params
      const payload: Record<string, unknown> = {
        name,
        sort_order: sortOrder ?? null,
      }
      if ("bankAccountId" in params) {
        payload.bank_account_id = bankAccountId ?? null
      }
      return pythonClient.patch<PaymentMethodApiRow>(`/payment-methods/${id}`, payload)
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
