"use client"

/**
 * estadisticas-ventas E1 (task 4.3) + E2 (tasks 7.1-7.4): hooks de lectura
 * del módulo de estadísticas — GET /reports/statistics/evolution, /products,
 * /breakdown y /clients. Molde de hooks/data/use-receivables.ts
 * (pythonClient + useQuery + mapper de lib/).
 *
 * Sin gate de plan: el historial se recorta en el servidor (D8) y la ventana
 * aplicada viaja en la respuesta para que la pantalla explique el recorte.
 *
 * E2: todos los hooks aceptan `branchId` (el BranchFilter compartido, URL
 * ?branch=). El filtro lo aplica el helper canónico de forma uniforme y
 * fail-closed en la base — acá sólo viaja.
 */

import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import {
  mapProductRankingPage,
  mapProductSalesDetail,
  mapSalesBreakdown,
  mapSalesEvolution,
  mapTopClients,
  type BreakdownDimension,
  type EvolutionBucket,
  type ProductRankingPage,
  type ProductRankingPageRaw,
  type ProductSalesDetail,
  type ProductSalesDetailRaw,
  type RankingOrder,
  type SalesBreakdown,
  type SalesBreakdownRaw,
  type SalesEvolution,
  type SalesEvolutionRaw,
  type TopClients,
  type TopClientsRaw,
} from "@/lib/sales-statistics"

function withBranch(params: Record<string, string>, branchId: string | null | undefined): URLSearchParams {
  const qs = new URLSearchParams(params)
  if (branchId) qs.set("branch_id", branchId)
  return qs
}

export interface UseSalesEvolutionParams {
  /** "YYYY-MM-DD" (fecha de negocio). */
  start: string
  end: string
  bucket: EvolutionBucket
  branchId?: string | null
}

export function useSalesEvolution({ start, end, bucket, branchId = null }: UseSalesEvolutionParams) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<SalesEvolution>({
    queryKey: queryKeys.salesStatistics.evolution(accountId, start, end, bucket, branchId),
    queryFn: async (): Promise<SalesEvolution> => {
      const qs = withBranch({ start, end, bucket }, branchId).toString()
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
  branchId?: string | null
}

export function useProductRanking({
  start, end, orderBy, groupVariants, page = 0, size = 25, branchId = null,
}: UseProductRankingParams) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<ProductRankingPage>({
    queryKey: queryKeys.salesStatistics.ranking(accountId, start, end, orderBy, groupVariants, page, size, branchId),
    queryFn: async (): Promise<ProductRankingPage> => {
      const qs = withBranch({
        start,
        end,
        order_by: orderBy,
        group_variants: String(groupVariants),
        page: String(page),
        size: String(size),
      }, branchId).toString()
      const raw = await pythonClient.get<ProductRankingPageRaw>(`/reports/statistics/products?${qs}`)
      return mapProductRankingPage(raw)
    },
    enabled: !!accountId && !!start && !!end,
    placeholderData: keepPreviousData,
  })
}

// ── E2 ──────────────────────────────────────────────────────────────────────

export interface UseSalesBreakdownParams {
  start: string
  end: string
  dimension: BreakdownDimension
  branchId?: string | null
}

/** Desglose del período por una dimensión. El tramo "Sin …" viaja con key
 *  null; día y hora llegan completos (7 / 24 filas). */
export function useSalesBreakdown({ start, end, dimension, branchId = null }: UseSalesBreakdownParams) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<SalesBreakdown>({
    queryKey: queryKeys.salesStatistics.breakdown(accountId, start, end, dimension, branchId),
    queryFn: async (): Promise<SalesBreakdown> => {
      const qs = withBranch({ start, end, dimension }, branchId).toString()
      const raw = await pythonClient.get<SalesBreakdownRaw>(`/reports/statistics/breakdown?${qs}`)
      return mapSalesBreakdown(raw)
    },
    enabled: !!accountId && !!start && !!end,
    placeholderData: keepPreviousData,
  })
}

export interface UseTopClientsParams {
  start: string
  end: string
  branchId?: string | null
  limit?: number
}

/** Top clientes del período (OQ-2: las ventas sin cliente viajan aparte). */
export function useTopClients({ start, end, branchId = null, limit = 10 }: UseTopClientsParams) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<TopClients>({
    queryKey: queryKeys.salesStatistics.topClients(accountId, start, end, branchId, limit),
    queryFn: async (): Promise<TopClients> => {
      const qs = withBranch({ start, end, limit: String(limit) }, branchId).toString()
      const raw = await pythonClient.get<TopClientsRaw>(`/reports/statistics/clients?${qs}`)
      return mapTopClients(raw)
    },
    enabled: !!accountId && !!start && !!end,
    placeholderData: keepPreviousData,
  })
}

// ── E3 ──────────────────────────────────────────────────────────────────────

export interface UseProductSalesEvolutionParams {
  productId: string
  start: string
  end: string
  bucket: EvolutionBucket
  branchId?: string | null
}

/** Detalle de un producto y su grupo de variantes (D12). Un producto de
 *  otra cuenta o inexistente responde 404 → estado de error de la pantalla,
 *  nunca un detalle vacío. */
export function useProductSalesEvolution({ productId, start, end, bucket, branchId = null }: UseProductSalesEvolutionParams) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<ProductSalesDetail>({
    queryKey: queryKeys.salesStatistics.productDetail(accountId, productId, start, end, bucket, branchId),
    queryFn: async (): Promise<ProductSalesDetail> => {
      const qs = withBranch({ start, end, bucket }, branchId).toString()
      const raw = await pythonClient.get<ProductSalesDetailRaw>(
        `/reports/statistics/products/${encodeURIComponent(productId)}?${qs}`,
      )
      return mapProductSalesDetail(raw)
    },
    enabled: !!accountId && !!productId && !!start && !!end,
    placeholderData: keepPreviousData,
    // Un 404 (producto ajeno / inexistente) no cambia reintentando.
    retry: false,
  })
}
