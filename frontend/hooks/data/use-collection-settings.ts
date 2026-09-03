"use client"

/**
 * cobranzas-vencimientos (tasks 8.5/9.7): plazo de pago por defecto de la
 * cuenta — GET/PATCH /settings/collections (rpc_set_default_payment_terms
 * detrás, guard is_account_writer). None = "sin plazo definido" (los cargos
 * nacen sin vencimiento) — NUNCA significa cero.
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

interface CollectionSettingsRaw {
  default_payment_terms_days: number | null
}

export interface CollectionSettings {
  defaultPaymentTermsDays: number | null
}

export function useCollectionSettings() {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<CollectionSettings>({
    queryKey: queryKeys.collectionSettings.get(accountId ?? ""),
    queryFn: async (): Promise<CollectionSettings> => {
      const raw = await pythonClient.get<CollectionSettingsRaw>("/settings/collections")
      return { defaultPaymentTermsDays: raw.default_payment_terms_days ?? null }
    },
    enabled: !!accountId,
    staleTime: 60 * 1000,
  })
}

export function useSetCollectionSettings() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (days: number | null): Promise<CollectionSettings> => {
      const raw = await pythonClient.patch<CollectionSettingsRaw>(
        "/settings/collections",
        { default_payment_terms_days: days },
      )
      return { defaultPaymentTermsDays: raw.default_payment_terms_days ?? null }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.collectionSettings.all() })
    },
  })
}
