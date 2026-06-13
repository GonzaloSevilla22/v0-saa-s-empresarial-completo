"use client"

import { useQuery } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import type { StockTransfer } from "@/lib/types"

interface TransferRow {
  id: string
  product_id: string
  product_name: string
  from_branch_id: string
  from_branch_name: string
  to_branch_id: string
  to_branch_name: string
  quantity: string | number
  status: string
  created_at: string
}

function mapRow(r: TransferRow): StockTransfer {
  return {
    id:             r.id,
    productId:      r.product_id,
    productName:    r.product_name,
    fromBranchId:   r.from_branch_id,
    fromBranchName: r.from_branch_name,
    toBranchId:     r.to_branch_id,
    toBranchName:   r.to_branch_name,
    quantity:       Number(r.quantity),
    status:         r.status,
    createdAt:      r.created_at,
  }
}

/**
 * C-26: historial de transferencias de una sucursal (como origen o destino).
 * Servido por el backend Python: GET /branches/{id}/transfers.
 */
export function useBranchTransfers(branchId: string | null) {
  const query = useQuery({
    queryKey: ["branch-transfers", branchId],
    queryFn: async (): Promise<StockTransfer[]> => {
      if (!branchId) return []
      const rows = await pythonClient.get<TransferRow[]>(`/branches/${branchId}/transfers`)
      return (rows ?? []).map(mapRow)
    },
    enabled: !!branchId,
    staleTime: 60 * 1000,
  })

  return {
    transfers: query.data ?? [],
    isLoading: query.isLoading,
    isError:   query.isError,
  }
}
