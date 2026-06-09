"use client"

import { useState, useCallback, useMemo } from "react"
import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Sale } from "@/lib/types"
import type { SaleCartItem } from "@/lib/cart-utils"
import {
  buildPaginationMeta,
  type PaginationMeta,
  type PageSizeOption,
} from "@/lib/pagination-utils"

// ── Types for API responses ───────────────────────────────────────────────────

interface SaleApiRow {
  id: string
  date: string
  product_id: string
  product_name?: string | null
  product?: { name: string } | null
  client_id: string | null
  client_name?: string | null
  client?: { name: string } | null
  quantity: number
  amount: string | number
  total: string | number | null
  currency: string
  operation_id?: string | null
}

interface SalesPageResponse {
  items: SaleApiRow[]
  total_operations: number
}

interface SaleOperationResult {
  operation_id: string
  operation_kind?: string | null
}

function mapSale(s: SaleApiRow): Sale {
  return {
    id:          s.id,
    date:        s.date.split("T")[0],
    productId:   s.product_id,
    productName: s.product_name || s.product?.name || "Eliminado",
    clientId:    s.client_id    || "",
    clientName:  s.client_name  || s.client?.name || "Consumidor Final",
    quantity:    Number(s.quantity),
    unitPrice:   Number(s.amount),
    total:       Number(s.total ?? s.amount),
    currency:    s.currency as Sale["currency"],
    operationId: s.operation_id ?? undefined,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

export function useSales() {
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
    queryKey: [...queryKeys.sales.lists(), queryParams],
    queryFn: async (): Promise<SalesPageResponse> => {
      const qs = new URLSearchParams(queryParams).toString()
      return pythonClient.get<SalesPageResponse>(`/sales?${qs}`)
    },
    staleTime: 30 * 1000,
  })

  const sales = useMemo(
    () => (query.data?.items ?? []).map(mapSale),
    [query.data],
  )

  const meta: PaginationMeta = useMemo(
    () => buildPaginationMeta(page, pageSize, query.data?.total_operations ?? 0),
    [page, pageSize, query.data?.total_operations],
  )

  // ── Mutations ─────────────────────────────────────────────────────────────
  const addSaleOperationMutation = useMutation({
    mutationFn: async ({
      items,
      meta: opMeta,
    }: {
      items: SaleCartItem[]
      meta: {
        idempotencyKey: string
        clientId: string | null
        date: string
        currency: string
        branchId?: string | null
        orgId: string
      }
    }): Promise<SaleOperationResult> => {
      const payload = {
        idempotency_key: opMeta.idempotencyKey,
        org_id:          opMeta.orgId,
        date:            opMeta.date,
        client_id:       opMeta.clientId ?? null,
        currency:        opMeta.currency,
        items: items.map(item => ({
          product_id: item.productId,
          amount:     item.unitPrice * (1 - item.discount / 100),
          quantity:   item.quantity,
          unit_id:    item.unitId ?? null,
        })),
      }
      return pythonClient.post<SaleOperationResult>("/sales", payload)
    },
    onSettled: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  const updateSaleMutation = useMutation({
    mutationFn: async (sale: Sale) => {
      return pythonClient.put<SaleApiRow>(`/sales/${sale.id}`, {
        amount:   sale.unitPrice,
        total:    sale.unitPrice * sale.quantity,
        quantity: sale.quantity,
        currency: sale.currency,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
    },
  })

  const deleteSaleMutation = useMutation({
    mutationFn: async (id: string) => {
      return pythonClient.delete<void>(`/sales/${id}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
    },
  })

  const deleteSalesByOperationMutation = useMutation({
    mutationFn: async (operationId: string) => {
      return pythonClient.delete<void>(`/sales?operation_id=${operationId}`)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
    },
  })

  const updateSaleOperationMutation = useMutation({
    mutationFn: async ({
      saleIds,
      newItems,
      meta: opMeta,
    }: {
      saleIds: string[]
      newItems: SaleCartItem[]
      meta: { clientId: string | null; date: string; currency: string; orgId: string }
    }) => {
      const items = newItems.map(item => ({
        product_id: item.productId,
        amount:     item.unitPrice * (1 - item.discount / 100),
        quantity:   item.quantity,
      }))
      return pythonClient.put<void>("/sales/operation", {
        sale_ids:  saleIds,
        client_id: opMeta.clientId ?? null,
        date:      opMeta.date,
        currency:  opMeta.currency,
        items,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  return {
    sales,
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
    addSaleOperation:       addSaleOperationMutation.mutateAsync,
    updateSale:             updateSaleMutation.mutateAsync,
    deleteSale:             deleteSaleMutation.mutateAsync,
    deleteSalesByOperation: deleteSalesByOperationMutation.mutateAsync,
    updateSaleOperation:    updateSaleOperationMutation.mutateAsync,
    addSaleOperationMutation,
    updateSaleMutation,
    deleteSaleMutation,
    deleteSalesByOperationMutation,
    updateSaleOperationMutation,
  }
}
