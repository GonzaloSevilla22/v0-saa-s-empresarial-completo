"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { Cashbox, CashMovementType } from "@/lib/types"

// ── API shapes (snake_case from Python backend) ───────────────────────────────

interface CashboxApiRow {
  id: string
  branch_id: string
  name: string
  currency: string
  created_at: string
}

interface CreateCashboxBody {
  branch_id: string
  name: string
  currency?: string
}

// ── Error translation ─────────────────────────────────────────────────────────

function translateRpcError(message: string): string {
  if (message.includes("cashbox_session_open"))  return "Ya hay una sesión de caja abierta para esta caja."
  if (message.includes("no_open_session"))        return "No hay sesión de caja abierta. Abrí una sesión primero."
  if (message.includes("session_not_open"))       return "La sesión de caja no está abierta."
  if (message.includes("branch_closed"))          return "La sucursal está cerrada. Abrila antes de operar la caja."
  if (message.includes("unauthorized"))           return "No tenés permisos para realizar esta acción."
  return message || "Ocurrió un error inesperado."
}

// ── Mapper ────────────────────────────────────────────────────────────────────

function mapCashbox(r: CashboxApiRow): Cashbox {
  return {
    id:        r.id,
    branchId:  r.branch_id,
    name:      r.name,
    currency:  r.currency,
    createdAt: r.created_at,
  }
}

// ── Hooks ─────────────────────────────────────────────────────────────────────

/**
 * List cashboxes for a branch.
 * Uses the Python backend: GET /branches/{branchId}/cashboxes
 */
export function useCashboxes(branchId: string | null) {
  return useQuery({
    queryKey: queryKeys.cashboxes.byBranch(branchId ?? ""),
    queryFn: async (): Promise<Cashbox[]> => {
      if (!branchId) return []
      const rows = await pythonClient.get<CashboxApiRow[]>(`/branches/${branchId}/cashboxes`)
      return rows.map(mapCashbox)
    },
    enabled: !!branchId,
    staleTime: 5 * 60 * 1000,
  })
}

/**
 * Create a new cashbox for a branch.
 * POST /cashboxes
 */
export function useCreateCashbox() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (payload: CreateCashboxBody): Promise<Cashbox> => {
      try {
        const row = await pythonClient.post<CashboxApiRow>("/cashboxes", payload)
        return mapCashbox(row)
      } catch (err) {
        throw new Error(translateRpcError((err as Error).message))
      }
    },
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({
        queryKey: queryKeys.cashboxes.byBranch(variables.branch_id),
      })
    },
  })
}
