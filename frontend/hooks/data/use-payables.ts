"use client"

/**
 * cobranzas-vencimientos (task 8.5): hooks de lectura del read-model de
 * cuentas por pagar — GET /reports/payables (paginado) y /summary. Espejo
 * exacto de use-receivables.ts (pythonClient + useQuery + mapper de lib/).
 *
 * Sin gate de plan. La invalidación tras pagos/reversas/compras a crédito
 * vive en los hooks de mutación (use-supplier-account / use-purchases), no
 * acá ni en las pantallas.
 */

import { useQuery } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import {
  mapPayableRow,
  mapPayablesSummary,
  type PayablePageRaw,
  type PayablesSummaryRaw,
} from "@/lib/receivables"
import type { AgingBucketFilter } from "@/lib/receivables-aging"
import type { PayableRow, PayablesSummary } from "@/lib/types"

/** Dominio cerrado de criterios de orden — espejo del Literal del backend. */
export type PayablesSort =
  | "balance"
  | "days_since_last_charge"
  | "days_since_last_payment"
  | "supplier_name"

export type PayablesSortDir = "asc" | "desc"

export interface PayablesPage {
  items: PayableRow[]
  total: number
  page: number
  pages: number
}

export interface UsePayablesParams {
  page?: number
  size?: number
  sort?: PayablesSort
  sortDir?: PayablesSortDir
  /** Filtro por tramo — resuelto en el SERVIDOR sobre el conjunto completo. */
  bucket?: AgingBucketFilter | null
}

export function usePayables(params: UsePayablesParams = {}) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const { page = 0, size = 25, sort = "balance", sortDir = "desc", bucket = null } = params

  return useQuery<PayablesPage>({
    queryKey: queryKeys.payables.list(accountId ?? "", page, size, sort, sortDir, bucket),
    queryFn: async (): Promise<PayablesPage> => {
      const qs = new URLSearchParams({
        page: String(page),
        size: String(size),
        sort,
        sort_dir: sortDir,
      })
      if (bucket) qs.set("bucket", bucket)
      const data = await pythonClient.get<PayablePageRaw>(
        `/reports/payables?${qs.toString()}`,
      )
      return {
        items: data.items.map(mapPayableRow),
        total: data.total,
        page: data.page,
        pages: data.pages,
      }
    },
    enabled: !!accountId,
  })
}

export function usePayablesSummary() {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<PayablesSummary>({
    queryKey: queryKeys.payables.summary(accountId ?? ""),
    queryFn: async (): Promise<PayablesSummary> => {
      const raw = await pythonClient.get<PayablesSummaryRaw>(
        "/reports/payables/summary",
      )
      return mapPayablesSummary(raw)
    },
    enabled: !!accountId,
    staleTime: 30 * 1000,
  })
}
