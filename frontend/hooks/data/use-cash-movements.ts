"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { CashMovement, CashMovementType } from "@/lib/types"

// ── API shapes (snake_case from Python backend) ───────────────────────────────

interface CashMovementApiRow {
  id: string
  session_id: string
  amount: string | number
  movement_type: CashMovementType
  reference_id: string | null
  balance_after: string | number
  created_by: string
  created_at: string
}

interface RegisterMovementBody {
  amount: number          // signed: + income, − expense
  movement_type: CashMovementType
  reference_id?: string
}

interface RegisterMovementResult {
  movement_id: string
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

function mapMovement(r: CashMovementApiRow): CashMovement {
  return {
    id:           r.id,
    sessionId:    r.session_id,
    amount:       Number(r.amount),
    movementType: r.movement_type,
    referenceId:  r.reference_id,
    balanceAfter: Number(r.balance_after),
    createdBy:    r.created_by,
    createdAt:    r.created_at,
  }
}

// ── Hooks ─────────────────────────────────────────────────────────────────────

/**
 * List all cash movements for a session.
 * GET /sessions/{sessionId}/movements
 */
export function useCashMovements(sessionId: string | null) {
  return useQuery({
    queryKey: queryKeys.cashMovements.bySession(sessionId ?? ""),
    queryFn: async (): Promise<CashMovement[]> => {
      if (!sessionId) return []
      const rows = await pythonClient.get<CashMovementApiRow[]>(
        `/sessions/${sessionId}/movements`
      )
      return rows.map(mapMovement)
    },
    enabled: !!sessionId,
    staleTime: 15 * 1000,
  })
}

/**
 * Register a new cash movement on the active session.
 * POST /sessions/{sessionId}/movements
 *
 * amount sign convention (OQ-2):
 *   income:  positive (+)  — sale, advance
 *   expense: negative (−)  — purchase_payment, expense, withdrawal
 */
export function useRegisterMovement(sessionId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (payload: RegisterMovementBody): Promise<RegisterMovementResult> => {
      try {
        return await pythonClient.post<RegisterMovementResult>(
          `/sessions/${sessionId}/movements`,
          payload
        )
      } catch (err) {
        throw new Error(translateRpcError((err as Error).message))
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.cashMovements.bySession(sessionId) })
      // Also invalidate the current session so the live balance updates
      queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
    },
  })
}
