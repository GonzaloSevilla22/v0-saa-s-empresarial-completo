"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { CashSession, CashMovementType } from "@/lib/types"

// ── API shapes (snake_case from Python backend) ───────────────────────────────

interface CashSessionApiRow {
  id: string
  cashbox_id: string
  status: "open" | "closed"
  opening_balance: string | number
  closing_balance: string | number | null
  counted_balance: string | number | null
  expected_balance: string | number | null
  difference: string | number | null
  opened_by: string
  closed_by: string | null
  opened_at: string
  closed_at: string | null
}

interface OpenSessionApiResult {
  session_id: string
  cashbox_id: string
  status: string
  opening_balance: string | number
}

interface CloseSessionApiResult {
  session_id: string
  status: string
  opening_balance: string | number
  expected_balance: string | number
  counted_balance: string | number
  difference: string | number
  closing_balance: string | number
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

function mapSession(r: CashSessionApiRow): CashSession {
  return {
    id:              r.id,
    cashboxId:       r.cashbox_id,
    status:          r.status,
    openingBalance:  Number(r.opening_balance),
    closingBalance:  r.closing_balance != null ? Number(r.closing_balance) : null,
    countedBalance:  r.counted_balance != null ? Number(r.counted_balance) : null,
    expectedBalance: r.expected_balance != null ? Number(r.expected_balance) : null,
    difference:      r.difference != null ? Number(r.difference) : null,
    openedBy:        r.opened_by,
    closedBy:        r.closed_by,
    openedAt:        r.opened_at,
    closedAt:        r.closed_at,
  }
}

// ── Hooks ─────────────────────────────────────────────────────────────────────

/**
 * Get the currently open session for a cashbox.
 * GET /cashboxes/{cashboxId}/current-session
 * Returns null if none is open (404 is swallowed as null).
 */
export function useCurrentSession(cashboxId: string | null) {
  return useQuery({
    queryKey: queryKeys.cashSessions.currentOpen(cashboxId ?? ""),
    queryFn: async (): Promise<CashSession | null> => {
      if (!cashboxId) return null
      try {
        const row = await pythonClient.get<CashSessionApiRow>(
          `/cashboxes/${cashboxId}/current-session`
        )
        return mapSession(row)
      } catch (err) {
        // 404 = no open session — not an error for the UI
        if ((err as Error).message?.includes("No hay sesión")) return null
        throw err
      }
    },
    enabled: !!cashboxId,
    staleTime: 30 * 1000,
  })
}

/**
 * List all sessions (open + closed) for a cashbox.
 * GET /cashboxes/{cashboxId}/sessions
 */
export function useCashSessions(cashboxId: string | null) {
  return useQuery({
    queryKey: queryKeys.cashSessions.byCashbox(cashboxId ?? ""),
    queryFn: async (): Promise<CashSession[]> => {
      if (!cashboxId) return []
      const rows = await pythonClient.get<CashSessionApiRow[]>(
        `/cashboxes/${cashboxId}/sessions`
      )
      return rows.map(mapSession)
    },
    enabled: !!cashboxId,
    staleTime: 60 * 1000,
  })
}

/**
 * Open a new cash session.
 * POST /cashboxes/{cashboxId}/sessions/open
 */
export function useOpenSession(cashboxId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (openingBalance: number): Promise<OpenSessionApiResult> => {
      try {
        return await pythonClient.post<OpenSessionApiResult>(
          `/cashboxes/${cashboxId}/sessions/open`,
          { opening_balance: openingBalance }
        )
      } catch (err) {
        throw new Error(translateRpcError((err as Error).message))
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.currentOpen(cashboxId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.byCashbox(cashboxId) })
    },
  })
}

/**
 * Close the current session with a counted balance (arqueo).
 * POST /sessions/{sessionId}/close
 */
export function useCloseSession() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({
      sessionId,
      countedBalance,
    }: {
      sessionId: string
      countedBalance: number
    }): Promise<CloseSessionApiResult> => {
      try {
        return await pythonClient.post<CloseSessionApiResult>(
          `/sessions/${sessionId}/close`,
          { counted_balance: countedBalance }
        )
      } catch (err) {
        throw new Error(translateRpcError((err as Error).message))
      }
    },
    onSuccess: (_data, variables) => {
      // We don't know the cashboxId here, so invalidate all cash session keys
      queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.cashMovements.all() })
    },
  })
}
