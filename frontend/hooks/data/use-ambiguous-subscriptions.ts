"use client"

/**
 * mp-real-subscriptions follow-up (task 8.8) — cola admin de suscripciones
 * ambiguas.
 *
 * El backend (PR #345) ya expone GET /payments/subscriptions/ambiguous y
 * POST /payments/subscriptions/ambiguous/{id}/resolve (admin-only,
 * `require_admin` server-side) — este hook solo los consume. También trae
 * useAccountSearch para el selector de cuenta destino, que consume el
 * endpoint nuevo GET /payments/accounts/search (mismo follow-up, task 8.8).
 *
 * Reglas duras: NUNCA `any`; tipos explícitos para el shape snake_case del
 * backend y el shape camelCase de dominio.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── API shape (snake_case from Python backend) ────────────────────────────

export interface AmbiguousSubscriptionApi {
  id: string
  preapproval_id: string
  preapproval_plan_id: string
  plan: string
  ambiguous_reason: string
  amount: number | null
  currency: string
  created_at: string
}

export interface AccountSearchResultApi {
  account_id: string
  owner_email: string
  owner_name: string | null
  billing_plan: string
}

// ── Domain types ───────────────────────────────────────────────────────────

export interface AmbiguousSubscription {
  id: string
  preapprovalId: string
  preapprovalPlanId: string
  plan: string
  ambiguousReason: string
  amount: number | null
  currency: string
  createdAt: string
}

export interface AccountSearchResult {
  accountId: string
  ownerEmail: string
  ownerName: string | null
  billingPlan: string
}

function mapAmbiguousSubscription(r: AmbiguousSubscriptionApi): AmbiguousSubscription {
  return {
    id: r.id,
    preapprovalId: r.preapproval_id,
    preapprovalPlanId: r.preapproval_plan_id,
    plan: r.plan,
    ambiguousReason: r.ambiguous_reason,
    amount: r.amount,
    currency: r.currency,
    createdAt: r.created_at,
  }
}

function mapAccountSearchResult(r: AccountSearchResultApi): AccountSearchResult {
  return {
    accountId: r.account_id,
    ownerEmail: r.owner_email,
    ownerName: r.owner_name,
    billingPlan: r.billing_plan,
  }
}

// ── Hook: cola de ambiguos + resolve ───────────────────────────────────────

export interface ResolveAmbiguousSubscriptionInput {
  subscriptionId: string
  accountId: string
}

/**
 * GET /payments/subscriptions/ambiguous · POST .../{id}/resolve
 * Solo admin — el backend rechaza con 403 si el JWT no corresponde a
 * profiles.role='admin'.
 */
export function useAmbiguousSubscriptions() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.ambiguousSubscriptions.all(),
    queryFn: async (): Promise<AmbiguousSubscription[]> => {
      const rows = await pythonClient.get<AmbiguousSubscriptionApi[]>(
        "/payments/subscriptions/ambiguous",
      )
      return rows.map(mapAmbiguousSubscription)
    },
  })

  const resolveMutation = useMutation({
    mutationFn: async ({
      subscriptionId,
      accountId,
    }: ResolveAmbiguousSubscriptionInput): Promise<{ ok: boolean }> => {
      return pythonClient.post<{ ok: boolean }>(
        `/payments/subscriptions/ambiguous/${subscriptionId}/resolve`,
        { account_id: accountId },
      )
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.ambiguousSubscriptions.all() })
    },
  })

  return {
    data:               query.data,
    isLoading:          query.isLoading,
    isError:            query.isError,
    error:              query.error,
    refetch:            query.refetch,
    resolveSubscription: resolveMutation.mutateAsync,
    resolveMutation,
  }
}

// ── Hook: búsqueda de cuentas (selector de destino) ────────────────────────

const MIN_QUERY_LENGTH = 2

/**
 * GET /payments/accounts/search?q=... — habilitado solo con >= 2
 * caracteres (el backend también lo exige, 422 si no). Solo admin.
 */
export function useAccountSearch(query: string) {
  const trimmed = query.trim()

  const result = useQuery({
    queryKey: queryKeys.accountSearch.query(trimmed),
    queryFn: async (): Promise<AccountSearchResult[]> => {
      const rows = await pythonClient.get<AccountSearchResultApi[]>(
        `/payments/accounts/search?q=${encodeURIComponent(trimmed)}`,
      )
      return rows.map(mapAccountSearchResult)
    },
    enabled: trimmed.length >= MIN_QUERY_LENGTH,
    staleTime: 30 * 1000,
  })

  return {
    data:       result.data,
    isFetching: result.isFetching,
    isError:    result.isError,
  }
}
