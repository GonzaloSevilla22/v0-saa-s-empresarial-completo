"use client"

/**
 * cobranzas-panel (task 4.4): hooks de lectura del read-model de cuentas por
 * cobrar — GET /reports/receivables (paginado) y /summary. Molde del cableado
 * de /reportes/formas-pago (pythonClient + useQuery + mapper de lib/).
 *
 * Sin gate de plan (D10). La invalidación tras cobros/reversas/ventas a
 * crédito vive en los hooks de mutación (D8), no acá ni en las pantallas.
 */

import { useQuery } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import {
  mapReceivableRow,
  mapReceivablesSummary,
  type ReceivablePageRaw,
  type ReceivablesSummaryRaw,
} from "@/lib/receivables"
import type { ReceivableRow, ReceivablesSummary } from "@/lib/types"

/** Dominio cerrado de criterios de orden — espejo del Literal del backend. */
export type ReceivablesSort =
  | "balance"
  | "days_since_last_charge"
  | "days_since_last_payment"
  | "client_name"

export type ReceivablesSortDir = "asc" | "desc"

export interface ReceivablesPage {
  items: ReceivableRow[]
  total: number
  page: number
  pages: number
}

export interface UseReceivablesParams {
  page?: number
  size?: number
  sort?: ReceivablesSort
  sortDir?: ReceivablesSortDir
}

export function useReceivables(params: UseReceivablesParams = {}) {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null
  const { page = 0, size = 25, sort = "balance", sortDir = "desc" } = params

  return useQuery<ReceivablesPage>({
    queryKey: queryKeys.receivables.list(accountId ?? "", page, size, sort, sortDir),
    queryFn: async (): Promise<ReceivablesPage> => {
      const qs = new URLSearchParams({
        page: String(page),
        size: String(size),
        sort,
        sort_dir: sortDir,
      }).toString()
      const data = await pythonClient.get<ReceivablePageRaw>(`/reports/receivables?${qs}`)
      return {
        items: data.items.map(mapReceivableRow),
        total: data.total,
        page: data.page,
        pages: data.pages,
      }
    },
    enabled: !!accountId,
  })
}

export function useReceivablesSummary() {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<ReceivablesSummary>({
    queryKey: queryKeys.receivables.summary(accountId ?? ""),
    queryFn: async (): Promise<ReceivablesSummary> => {
      const raw = await pythonClient.get<ReceivablesSummaryRaw>(
        "/reports/receivables/summary",
      )
      return mapReceivablesSummary(raw)
    },
    enabled: !!accountId,
    staleTime: 30 * 1000,
  })
}
