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

// Residuos (b)/(c) de mp-real-subscriptions (ver CHANGES.md "Hotfixes
// post-archive #511-#517"): "Descartar" una fila ambigua sin cuenta
// legítima + "Replicar cuotas" desde la sección "Suscripciones recientes".

export interface RecentSubscriptionApi {
  id: string
  plan: string
  status: string
  account_id: string | null
  account_name: string | null
  next_payment_date: string | null
  last_payment_status: string | null
  retry_state: string
  updated_at: string
}

export interface ReplaySubscriptionChargesResultApi {
  ok: boolean
  applied: string[]
  already_applied: string[]
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

export interface RecentSubscription {
  id: string
  plan: string
  status: string
  accountId: string | null
  accountName: string | null
  nextPaymentDate: string | null
  lastPaymentStatus: string | null
  retryState: string
  updatedAt: string
}

export interface ReplaySubscriptionChargesResult {
  ok: boolean
  applied: string[]
  alreadyApplied: string[]
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

function mapRecentSubscription(r: RecentSubscriptionApi): RecentSubscription {
  return {
    id: r.id,
    plan: r.plan,
    status: r.status,
    accountId: r.account_id,
    accountName: r.account_name,
    nextPaymentDate: r.next_payment_date,
    lastPaymentStatus: r.last_payment_status,
    retryState: r.retry_state,
    updatedAt: r.updated_at,
  }
}

function mapReplayResult(r: ReplaySubscriptionChargesResultApi): ReplaySubscriptionChargesResult {
  return {
    ok: r.ok,
    applied: r.applied,
    alreadyApplied: r.already_applied,
  }
}

// ── Hook: cola de ambiguos + resolve ───────────────────────────────────────

export interface ResolveAmbiguousSubscriptionInput {
  subscriptionId: string
  accountId: string
}

export interface DiscardAmbiguousSubscriptionInput {
  subscriptionId: string
  reason?: string | null
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

  // Descartar (residuo (b)): saca una fila ambigua sin cuenta legítima de
  // la cola — NUNCA toca accounts/billing_events (a diferencia de
  // resolveSubscription). La fila reaparece en "Suscripciones recientes"
  // como 'cancelled' sin cuenta, así que invalida las dos queries.
  const discardMutation = useMutation({
    mutationFn: async ({
      subscriptionId,
      reason,
    }: DiscardAmbiguousSubscriptionInput): Promise<{ id: string; status: string }> => {
      return pythonClient.post<{ id: string; status: string }>(
        `/payments/subscriptions/ambiguous/${subscriptionId}/discard`,
        { reason: reason ?? null },
      )
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.ambiguousSubscriptions.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.recentSubscriptions.all() })
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
    discardSubscription: discardMutation.mutateAsync,
    discardMutation,
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

// ── Hook: "Suscripciones recientes" + Replicar cuotas (residuo (c)) ────────

const DEFAULT_RECENT_LIMIT = 20

/**
 * GET /payments/subscriptions/recent?limit=... · POST
 * /payments/subscriptions/{id}/replay-charges (endpoint ya existente,
 * hotfix H3 2026-09-04). Solo admin.
 */
export function useRecentSubscriptions(limit: number = DEFAULT_RECENT_LIMIT) {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.recentSubscriptions.list(limit),
    queryFn: async (): Promise<RecentSubscription[]> => {
      const rows = await pythonClient.get<RecentSubscriptionApi[]>(
        `/payments/subscriptions/recent?limit=${limit}`,
      )
      return rows.map(mapRecentSubscription)
    },
  })

  const replayMutation = useMutation({
    mutationFn: async (subscriptionId: string): Promise<ReplaySubscriptionChargesResult> => {
      const result = await pythonClient.post<ReplaySubscriptionChargesResultApi>(
        `/payments/subscriptions/${subscriptionId}/replay-charges`,
        {},
      )
      return mapReplayResult(result)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.recentSubscriptions.all() })
    },
  })

  return {
    data:       query.data,
    isLoading:  query.isLoading,
    isError:    query.isError,
    error:      query.error,
    refetch:    query.refetch,
    replaySubscriptionCharges: replayMutation.mutateAsync,
    replayMutation,
  }
}
