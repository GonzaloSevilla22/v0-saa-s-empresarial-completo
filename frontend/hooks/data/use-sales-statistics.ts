"use client"

/**
 * estadisticas-ventas E1 (task 4.3): hooks de lectura del módulo de
 * estadísticas — GET /reports/statistics/evolution y /products. Molde de
 * hooks/data/use-receivables.ts (pythonClient + useQuery + mapper de lib/).
 *
 * Sin gate de plan: el historial se recorta en el servidor (D8) y la ventana
 * aplicada viaja en la respuesta para que la pantalla explique el recorte.
 */

import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import {
  mapProductRankingPage,
  mapSalesEvolution,
  type EvolutionBucket,
  type ProductRankingPage,
  type ProductRankingPageRaw,
  type RankingOrder,
  type SalesEvolution,
  type SalesEvolutionRaw,
} from "@/lib/sales-statistics"

export interface UseSalesEvolutionParams {
  /** "YYYY-MM-DD" (fecha de negocio). */
  start: string
  end: string
  bucket: EvolutionBucket
}

export function useSalesEvolution({ start, end, bucket }: UseSalesEvolutionParams) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<SalesEvolution>({
    queryKey: queryKeys.salesStatistics.evolution(accountId, start, end, bucket),
    queryFn: async (): Promise<SalesEvolution> => {
      const qs = new URLSearchParams({ start, end, bucket }).toString()
      const raw = await pythonClient.get<SalesEvolutionRaw>(`/reports/statistics/evolution?${qs}`)
      return mapSalesEvolution(raw)
    },
    enabled: !!accountId && !!start && !!end,
    placeholderData: keepPreviousData,
  })
}

export interface UseProductRankingParams {
  start: string
  end: string
  orderBy: RankingOrder
  groupVariants: boolean
  page?: number
  size?: number
}

export function useProductRanking({
  start, end, orderBy, groupVariants, page = 0, size = 25,
}: UseProductRankingParams) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<ProductRankingPage>({
    queryKey: queryKeys.salesStatistics.ranking(accountId, start, end, orderBy, groupVariants, page, size),
    queryFn: async (): Promise<ProductRankingPage> => {
      const qs = new URLSearchParams({
        start,
        end,
        order_by: orderBy,
        group_variants: String(groupVariants),
        page: String(page),
        size: String(size),
      }).toString()
      const raw = await pythonClient.get<ProductRankingPageRaw>(`/reports/statistics/products?${qs}`)
      return mapProductRankingPage(raw)
    },
    enabled: !!accountId && !!start && !!end,
    placeholderData: keepPreviousData,
  })
}
