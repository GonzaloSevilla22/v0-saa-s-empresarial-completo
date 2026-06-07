"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Purchase } from "@/lib/types"
import type { PurchaseCartItem } from "@/lib/cart-utils"

// ── Types for API responses ───────────────────────────────────────────────────

interface PurchaseApiRow {
  id: string
  date: string
  product_id: string
  product?: { name: string } | null
  quantity: number
  amount: string | number
  total: string | number | null
  operation_id?: string | null
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
    productName: p.product?.name || "Eliminado",
    quantity:    Number(p.quantity),
    unitCost:    Number(p.amount),
    total:       Number(p.total ?? p.amount),
    operationId: p.operation_id ?? undefined,
  }
}

// ── Hook ─────────────────────────────────────────────────────────────────────

/**
 * Returns purchases list + mutations (add operation, update, delete) via Python API.
 */
export function usePurchases() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.purchases.lists(),
    queryFn: async (): Promise<Purchase[]> => {
      const data = await pythonClient.get<PurchaseApiRow[]>("/purchases")
      return data.map(mapPurchase)
    },
    staleTime: 30 * 1000, // 30 sec
  })

  const addPurchaseOperationMutation = useMutation({
    mutationFn: async ({
      items,
      meta,
    }: {
      items: PurchaseCartItem[]
      meta: {
        idempotencyKey: string
        date: string
        description: string
        branchId?: string | null
        orgId: string
      }
    }): Promise<PurchaseOperationResult> => {
      const payload = {
        idempotency_key: meta.idempotencyKey,
        org_id:          meta.orgId,
        date:            meta.date,
        items: items.map(item => ({
          product_id:  item.productId,
          amount:      item.unitCost,
          quantity:    item.quantity,
          description: meta.description || null,
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
      meta,
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
        date:         meta.date,
        description:  meta.description || null,
        items,
      })
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.purchases.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
    },
  })

  return {
    purchases:                  query.data ?? [],
    isLoading:                  query.isLoading,
    isError:                    query.isError,
    error:                      query.error,
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
