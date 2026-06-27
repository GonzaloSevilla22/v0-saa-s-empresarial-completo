"use client"

import { useState, useCallback, useMemo } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Purchase } from "@/lib/types"
import type { PurchaseCartItem } from "@/lib/cart-utils"
import {
  buildPaginationMeta,
  type PaginationMeta,
  type PageSizeOption,
} from "@/lib/pagination-utils"

// ── Types for API responses ───────────────────────────────────────────────────

interface PurchaseApiRow {
  id: string
  date: string
  product_id: string
  product_name?: string | null
  product?: { name: string } | null
  quantity: number
  amount: string | number
  total: string | number | null
  operation_id?: string | null
  description?: string | null
}

interface PurchasesPageResponse {
  items: PurchaseApiRow[]
  total_operations: number
}

interface PurchaseOperationResult {
  operation_id: string
  operation_kind?: string | null
}

function mapPurchase(p: PurchaseApiRow): Purchase {
  return {
    id:          p.id,
    date:        p.date.split("T")[0],
    productId:   p.product_id,
    productName: p.product_name || p.product?.name || "Eliminado",
    quantity:    Number(p.quantity),
    unitCost:    Number(p.amount),
    total:       Number(p.total ?? p.amount),
    description: p.description ?? undefined,
    operationId: p.operation_id ?? undefined,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

export function usePurchases() {
  const queryClient = useQueryClient()

  // ── Pagination & filter state ─────────────────────────────────────────────
  const [page,     setPageState]     = useState(0)
  const [pageSize, setPageSizeState] = useState<PageSizeOption>(25)
  const [dateFrom, setDateFromState] = useState("")
  const [dateTo,   setDateToState]   = useState("")

  const setPage = useCallback((p: number) => setPageState(p), [])
  const setPageSize = useCallback((s: PageSizeOption) => {
    setPageSizeState(s)
    setPageState(0)
  }, [])
  const setDateFrom = useCallback((v: string) => { setDateFromState(v); setPageState(0) }, [])
  const setDateTo   = useCallback((v: string) => { setDateToState(v);   setPageState(0) }, [])
  const clearFilters = useCallback(() => {
    setDateFromState("")
    setDateToState("")
    setPageState(0)
  }, [])

  // ── List query ────────────────────────────────────────────────────────────
  const queryParams = useMemo(() => {
    const p: Record<string, string> = {
      page:      String(page),
      page_size: String(pageSize),
    }
    if (dateFrom) p.date_from = dateFrom
    if (dateTo)   p.date_to   = dateTo
    return p
  }, [page, pageSize, dateFrom, dateTo])

  const query = useQuery({
    queryKey: [...queryKeys.purchases.lists(), queryParams],
    queryFn: async (): Promise<PurchasesPageResponse> => {
      const qs = new URLSearchParams(queryParams).toString()
      return pythonClient.get<PurchasesPageResponse>(`/purchases?${qs}`)
    },
    staleTime: 30 * 1000,
  })

  const purchases = useMemo(
    () => (query.data?.items ?? []).map(mapPurchase),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total_operations ?? 0),
    [page, pageSize, query.data?.total_operations],
  )

  // ── Mutations ─────────────────────────────────────────────────────────────
  const addPurchaseOperationMutation = useMutation({
    mutationFn: async ({
      items,
      meta: opMeta,
    }: {
      items: PurchaseCartItem[]
      meta: {
        idempotencyKey: string
        date: string
        description: string
        branchId?: string | null
        orgId: string
        /** cost-center-dimension: optional analytic dimension for the whole operation */
        costCenterId?: string | null
      }
    }): Promise<PurchaseOperationResult> => {
      const payload = {
        idempotency_key:  opMeta.idempotencyKey,
        org_id:           opMeta.orgId,
        date:             opMeta.date,
        // cost-center-dimension: shared by all lines of the operation
        cost_center_id:   opMeta.costCenterId ?? null,
        items: items.map(item => ({
          product_id:  item.productId,
          amount:      item.unitCost,
          quantity:    item.quantity,
          description: opMeta.description || null,
          unit_id:     item.unitId ?? null,
        })),
      }
      return pythonClient.post<PurchaseOperationResult>("/purchases", payload)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  const updatePurchaseMutation = useMutation({
    mutationFn: async (purchase: Purchase) => {
      return pythonClient.put<PurchaseApiRow>(`/purchases/${purchase.id}`, {
        amount:   purchase.unitCost,
        total:    purchase.unitCost * purchase.quantity,
        quantity: purchase.quantity,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
    },
  })

  const deletePurchaseMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/purchases/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
    },
  })

  const deletePurchasesByOperationMutation = useMutation({
    mutationFn: async (operationId: string) => {
      return pythonClient.delete<void>(`/purchases?operation_id=${operationId}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
    },
  })

  const updatePurchaseOperationMutation = useMutation({
    mutationFn: async ({
      purchaseIds,
      newItems,
      meta: opMeta,
    }: {
      purchaseIds: string[]
      newItems: PurchaseCartItem[]
      meta: { date: string; description: string; orgId: string }
    }) => {
      const items = newItems.map(item => ({
        product_id: item.productId,
        amount:     item.unitCost,
        quantity:   item.quantity,
      }))
      return pythonClient.put<void>("/purchases/operation", {
        purchase_ids: purchaseIds,
        date:         opMeta.date,
        description:  opMeta.description || null,
        items,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  return {
    purchases,
    meta,
    isLoading: query.isLoading,
    isError:   query.isError,
    error:     query.error ? (query.error as Error).message : null,
    dateFrom,
    setDateFrom,
    dateTo,
    setDateTo,
    clearFilters,
    setPage,
    setPageSize,
    refetch: query.refetch,
    addPurchaseOperation:       addPurchaseOperationMutation.mutateAsync,
    updatePurchase:             updatePurchaseMutation.mutateAsync,
    deletePurchase:             deletePurchaseMutation.mutateAsync,
    deletePurchasesByOperation: deletePurchasesByOperationMutation.mutateAsync,
    updatePurchaseOperation:    updatePurchaseOperationMutation.mutateAsync,
    addPurchaseOperationMutation,
    updatePurchaseMutation,
    deletePurchaseMutation,
    deletePurchasesByOperationMutation,
    updatePurchaseOperationMutation,
  }
}
