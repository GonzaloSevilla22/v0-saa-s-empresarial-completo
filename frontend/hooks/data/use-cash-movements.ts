"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { CashMovement, CashMovementHistoryRow, CashMovementType, Page } from "@/lib/types"
import type { LedgerFetchParams } from "@/lib/ledger/types"

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
  description: string | null
}

interface CashMovementHistoryApiRow extends CashMovementApiRow {
  session_opened_at: string
  session_status: "open" | "closed"
}

interface RegisterMovementBody {
  amount: number          // signed: + income, − expense (adjustment: signo libre)
  movement_type: CashMovementType
  reference_id?: string
  description?: string    // obligatorio no vacío solo para movement_type='adjustment'
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
    description:  r.description,
  }
}

function mapHistoryRow(r: CashMovementHistoryApiRow): CashMovementHistoryRow {
  return {
    ...mapMovement(r),
    sessionOpenedAt: r.session_opened_at,
    sessionStatus:   r.session_status,
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
      // banco-caja-historial-ajustes: el historial por caja (D2,
      // LedgerMovementsPanel) NO usa TanStack Query — administra su propio
      // estado imperativo (fetchCashMovementsByCashboxPage). Refrescarlo tras
      // un movimiento/ajuste es responsabilidad del componente que monta el
      // panel (bumpear su `refreshToken`), no de esta mutation.
    },
  })
}

/**
 * Historial de movimientos de UNA CAJA — todas las sesiones, no solo la
 * abierta (D2 del design, ledger-movement-history). Paginado server-side.
 * GET /cashboxes/{cashboxId}/movements
 *
 * Función plana (no hook): `LedgerMovementsPanel` administra su propio
 * estado de acumulación de páginas ("Ver más") de forma imperativa —igual
 * que el molde de Stock, que tampoco usa TanStack Query para esto—, así que
 * `config.fetchPage` necesita una función invocable directamente, no un
 * hook con reglas de invocación condicionadas al render.
 */
export async function fetchCashMovementsByCashboxPage(
  cashboxId: string,
  params: LedgerFetchParams
): Promise<Page<CashMovementHistoryRow>> {
  const qs = new URLSearchParams()
  qs.set("page", String(params.page))
  qs.set("size", String(params.size))
  if (params.q) qs.set("q", params.q)
  if (params.from) qs.set("from", params.from)
  if (params.to) qs.set("to", params.to)
  for (const t of params.types ?? []) qs.append("types", t)

  const data = await pythonClient.get<{
    items: CashMovementHistoryApiRow[]
    total: number
    page: number
    pages: number
  }>(`/cashboxes/${cashboxId}/movements?${qs.toString()}`)

  return { ...data, items: data.items.map(mapHistoryRow) }
}
