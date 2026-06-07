"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { useMemo } from "react"
import { createClient } from "@/lib/supabase/client"
import { useAuth } from "@/contexts/auth-context"
import { queryKeys } from "@/lib/query-keys"
import type {
  BranchStockWithProduct,
  TransferStockResult,
  AdjustBranchStockResult,
} from "@/lib/types"

// ── Raw DB row shape returned by the JOIN query ───────────────────────────────
interface BranchStockRow {
  id: string
  account_id: string
  product_id: string
  branch_id: string
  quantity: number
  min_stock: number
  products: {
    name: string
    sku: string | null
  } | null
}

function mapRow(r: BranchStockRow): BranchStockWithProduct {
  return {
    id:          r.id,
    accountId:   r.account_id,
    productId:   r.product_id,
    branchId:    r.branch_id,
    quantity:    r.quantity,
    minStock:    r.min_stock,
    productName: r.products?.name ?? "Producto sin nombre",
    productSku:  r.products?.sku ?? null,
  }
}

export function translateBranchStockError(message: string): string {
  if (message.includes("insufficient_branch_stock"))
    return "Stock insuficiente en esta sucursal."
  if (message.includes("same_branch_transfer_not_allowed"))
    return "El origen y destino de la transferencia deben ser diferentes."
  if (message.includes("branch_not_found"))
    return "La sucursal no existe o no está activa."
  if (message.includes("unauthorized"))
    return "No tenés permisos para realizar esta acción."
  if (message.includes("Quantity must be greater than zero"))
    return "La cantidad debe ser mayor a cero."
  if (message.includes("New quantity must be >= 0"))
    return "La cantidad no puede ser negativa."
  return message || "Ocurrió un error inesperado."
}

/**
 * Fetches all branch_stock rows for a given branch, joined with product data.
 * Returns only rows where quantity > 0 or min_stock > 0 (i.e., relevant rows).
 */
export function useBranchStock(branchId: string) {
  const { user } = useAuth()
  const supabase  = useMemo(() => createClient(), [])
  const accountId = user?.accountId ?? null

  const query = useQuery({
    queryKey: queryKeys.branchStock.byBranch(branchId),
    queryFn:  async (): Promise<BranchStockWithProduct[]> => {
      if (!accountId || !branchId) return []

      const { data, error } = await supabase
        .from("branch_stock")
        .select(`
          id,
          account_id,
          product_id,
          branch_id,
          quantity,
          min_stock,
          products (
            name,
            sku
          )
        `)
        .eq("account_id", accountId)
        .eq("branch_id", branchId)
        .order("quantity", { ascending: false })

      if (error) throw error
      return (data ?? []).map((r) => mapRow(r as unknown as BranchStockRow))
    },
    enabled:   !!accountId && !!branchId,
    staleTime: 30 * 1000, // 30 seconds — stock changes frequently
  })

  return {
    branchStock: query.data ?? [],
    isLoading:   query.isLoading,
    isError:     query.isError,
  }
}

// ── Params types ──────────────────────────────────────────────────────────────

export interface AdjustBranchStockParams {
  productId:    string
  branchId:     string
  newQuantity:  number
  reason:       string
}

export interface TransferStockParams {
  productId:    string
  fromBranchId: string
  toBranchId:   string
  quantity:     number
}

/**
 * Mutation to adjust stock for a product in a specific branch.
 * Calls rpc_adjust_branch_stock. Only owner/admin can call this.
 */
export function useAdjustBranchStock() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (params: AdjustBranchStockParams): Promise<AdjustBranchStockResult> => {
      const { data, error } = await supabase.rpc("rpc_adjust_branch_stock", {
        p_product_id:   params.productId,
        p_branch_id:    params.branchId,
        p_new_quantity: params.newQuantity,
        p_reason:       params.reason,
      })
      if (error) throw new Error(translateBranchStockError(error.message))
      return data as AdjustBranchStockResult
    },
    onSuccess: (_data, params) => {
      queryClient.invalidateQueries({
        queryKey: queryKeys.branchStock.byBranch(params.branchId),
      })
    },
  })
}

/**
 * Mutation to transfer stock between two branches for a given product.
 * Calls rpc_transfer_stock. Only owner/admin can call this.
 */
export function useTransferStock() {
  const queryClient = useQueryClient()
  const supabase    = useMemo(() => createClient(), [])

  return useMutation({
    mutationFn: async (params: TransferStockParams): Promise<TransferStockResult> => {
      const { data, error } = await supabase.rpc("rpc_transfer_stock", {
        p_product_id:     params.productId,
        p_from_branch_id: params.fromBranchId,
        p_to_branch_id:   params.toBranchId,
        p_quantity:       params.quantity,
      })
      if (error) throw new Error(translateBranchStockError(error.message))
      return data as TransferStockResult
    },
    onSuccess: (_data, params) => {
      // Invalidate both source and destination branch stock queries
      queryClient.invalidateQueries({
        queryKey: queryKeys.branchStock.byBranch(params.fromBranchId),
      })
      queryClient.invalidateQueries({
        queryKey: queryKeys.branchStock.byBranch(params.toBranchId),
      })
    },
  })
}
