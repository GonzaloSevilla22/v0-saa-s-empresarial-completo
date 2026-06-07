"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Sale } from "@/lib/types"
import type { SaleCartItem } from "@/lib/cart-utils"

// ── Types for API responses ───────────────────────────────────────────────────

interface SaleApiRow {
  id: string
  date: string
  product_id: string
  product?: { name: string } | null
  client_id: string | null
  client?: { name: string } | null
  quantity: number
  amount: string | number
  total: string | number | null
  currency: string
  operation_id?: string | null
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
    productName: s.product?.name || "Eliminado",
    clientId:    s.client_id    || "",
    clientName:  s.client?.name || "Consumidor Final",
    quantity:    Number(s.quantity),
    unitPrice:   Number(s.amount),
    total:       Number(s.total ?? s.amount),
    currency:    s.currency as Sale["currency"],
    operationId: s.operation_id ?? undefined,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Returns sales list + mutations (add operation, update, delete) via Python API.
 * addSaleOperation uses optimistic update.
 */
export function useSales() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.sales.lists(),
    queryFn: async (): Promise<Sale[]> => {
      const data = await pythonClient.get<SaleApiRow[]>("/sales")
      return data.map(mapSale)
    },
    staleTime: 30 * 1000, // 30 sec — sales change frequently
  })

  // ── addSaleOperation (idempotent, multi-item) with optimistic update ─────────
  const addSaleOperationMutation = useMutation({
    mutationFn: async ({
      items,
      meta,
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
        idempotency_key: meta.idempotencyKey,
        org_id:          meta.orgId,
        date:            meta.date,
        items: items.map(item => ({
          product_id: item.productId,
          amount:     item.unitPrice * (1 - item.discount / 100),
          quantity:   item.quantity,
          unit_id:    item.unitId ?? null,
        })),
      }
      return pythonClient.post<SaleOperationResult>("/sales", payload)
    },
    onMutate: async ({ items, meta }) => {
      // Cancel in-flight queries for sales
      await queryClient.cancelQueries({ queryKey: queryKeys.sales.lists() })

      // Snapshot previous state for rollback
      const previous = queryClient.getQueryData<Sale[]>(queryKeys.sales.lists())

      // Optimistic insert — temporary IDs
      const optimisticSales: Sale[] = items.map((item, i) => ({
        id:          `optimistic-${meta.idempotencyKey}-${i}`,
        date:        meta.date,
        productId:   item.productId,
        productName: item.productName,
        clientId:    meta.clientId || "",
        clientName:  "Consumidor Final",
        quantity:    item.quantity,
        unitPrice:   item.unitPrice * (1 - item.discount / 100),
        total:       item.subtotal,
        currency:    meta.currency as Sale["currency"],
        operationId: meta.idempotencyKey,
      }))

      queryClient.setQueryData<Sale[]>(queryKeys.sales.lists(), old =>
        [...optimisticSales, ...(old ?? [])]
      )

      return { previous }
    },
    onError: (_err, _variables, context) => {
      // Rollback on error
      if (context?.previous) {
        queryClient.setQueryData(queryKeys.sales.lists(), context.previous)
      }
    },
    onSettled: () => {
      // Full invalidation after settlement to get accurate server state
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
      meta,
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
        client_id: meta.clientId ?? null,
        date:      meta.date,
        currency:  meta.currency,
        items,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  return {
    sales:                 query.data ?? [],
    isLoading:             query.isLoading,
    isError:               query.isError,
    error:                 query.error,
    addSaleOperation:      addSaleOperationMutation.mutateAsync,
    updateSale:            updateSaleMutation.mutateAsync,
    deleteSale:            deleteSaleMutation.mutateAsync,
    deleteSalesByOperation: deleteSalesByOperationMutation.mutateAsync,
    updateSaleOperation:   updateSaleOperationMutation.mutateAsync,
    addSaleOperationMutation,
    updateSaleMutation,
    deleteSaleMutation,
    deleteSalesByOperationMutation,
    updateSaleOperationMutation,
  }
}
