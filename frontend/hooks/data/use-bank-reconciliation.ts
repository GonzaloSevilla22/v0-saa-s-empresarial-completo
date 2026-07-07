"use client"

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import type { NormalizedStatementLine } from "@/lib/bank-statement-parser"

// ── API shapes (snake_case from Python backend) ────────────────────────────────

export interface StatementImportApi {
  id: string
  bank_account_id: string
  file_name: string
  period_from: string
  period_to: string
  line_count: number
  created_at: string
}

export interface StatementImportResultApi {
  import_id: string
  line_count: number
  period_from: string | null
  period_to: string | null
  replayed: boolean
}

export interface ReconciliationSessionApi {
  id: string
  bank_account_id: string
  status: "open" | "closed"
  period_from: string
  period_to: string
  statement_closing_balance: string | number
  ledger_closing_balance: string | number | null
  difference: string | number | null
  close_reason: string | null
  opened_at: string | null
  closed_at: string | null
}

export interface StatementLineApi {
  id: string
  line_no: number
  value_date: string
  description: string | null
  amount: string | number
  balance: string | number | null
  matched: boolean
}

export interface PendingMovementApi {
  id: string
  amount: string | number
  movement_type: string
  value_date: string | null
  description: string | null
  balance_after: string | number
  reconciliation_status: string
}

export interface SessionPendingApi {
  session: ReconciliationSessionApi
  pending_lines: StatementLineApi[]
  pending_movements: PendingMovementApi[]
}

export interface SuggestionApi {
  statement_line_id: string
  bank_movement_id: string
  amount: string | number
  line_value_date: string
  movement_value_date: string | null
  line_description: string | null
  movement_description: string | null
}

export interface MatchGroupResultApi {
  match_group: string
  session_id: string
  line_count: number
  movement_count: number
  amount: string | number
}

// ── Domain types ───────────────────────────────────────────────────────────────

export interface ReconciliationSession {
  id: string
  bankAccountId: string
  status: "open" | "closed"
  periodFrom: string
  periodTo: string
  statementClosingBalance: number
  ledgerClosingBalance: number | null
  difference: number | null
  closeReason: string | null
  openedAt: string | null
  closedAt: string | null
}

export interface StatementLine {
  id: string
  lineNo: number
  valueDate: string
  description: string | null
  amount: number
  balance: number | null
  matched: boolean
}

export interface PendingMovement {
  id: string
  amount: number
  movementType: string
  valueDate: string | null
  description: string | null
  balanceAfter: number
  reconciliationStatus: string
}

export interface MatchSuggestion {
  statementLineId: string
  bankMovementId: string
  amount: number
  lineValueDate: string
  movementValueDate: string | null
  lineDescription: string | null
  movementDescription: string | null
}

// ── Mappers ────────────────────────────────────────────────────────────────────

export function mapSession(r: ReconciliationSessionApi): ReconciliationSession {
  return {
    id:                      r.id,
    bankAccountId:           r.bank_account_id,
    status:                  r.status,
    periodFrom:              r.period_from,
    periodTo:                r.period_to,
    statementClosingBalance: Number(r.statement_closing_balance),
    ledgerClosingBalance:    r.ledger_closing_balance === null ? null : Number(r.ledger_closing_balance),
    difference:              r.difference === null ? null : Number(r.difference),
    closeReason:             r.close_reason,
    openedAt:                r.opened_at,
    closedAt:                r.closed_at,
  }
}

export function mapLine(r: StatementLineApi): StatementLine {
  return {
    id:          r.id,
    lineNo:      r.line_no,
    valueDate:   r.value_date,
    description: r.description,
    amount:      Number(r.amount),
    balance:     r.balance === null ? null : Number(r.balance),
    matched:     r.matched,
  }
}

export function mapMovement(r: PendingMovementApi): PendingMovement {
  return {
    id:                   r.id,
    amount:               Number(r.amount),
    movementType:         r.movement_type,
    valueDate:            r.value_date,
    description:          r.description,
    balanceAfter:         Number(r.balance_after),
    reconciliationStatus: r.reconciliation_status,
  }
}

export function mapSuggestion(r: SuggestionApi): MatchSuggestion {
  return {
    statementLineId:     r.statement_line_id,
    bankMovementId:      r.bank_movement_id,
    amount:              Number(r.amount),
    lineValueDate:       r.line_value_date,
    movementValueDate:   r.movement_value_date,
    lineDescription:     r.line_description,
    movementDescription: r.movement_description,
  }
}

// ── Queries ────────────────────────────────────────────────────────────────────

export function useStatementImports(bankAccountId: string | null) {
  return useQuery({
    queryKey: queryKeys.bankReconciliation.imports(bankAccountId ?? ""),
    enabled: !!bankAccountId,
    queryFn: async () => {
      const rows = await pythonClient.get<StatementImportApi[]>(
        `/bank-accounts/${bankAccountId}/statement-imports`
      )
      return rows
    },
  })
}

export function useReconciliationSessions(bankAccountId: string | null) {
  return useQuery({
    queryKey: queryKeys.bankReconciliation.sessions(bankAccountId ?? ""),
    enabled: !!bankAccountId,
    queryFn: async (): Promise<ReconciliationSession[]> => {
      const rows = await pythonClient.get<ReconciliationSessionApi[]>(
        `/bank-accounts/${bankAccountId}/reconciliation-sessions`
      )
      return rows.map(mapSession)
    },
  })
}

export function useSessionPending(sessionId: string | null) {
  return useQuery({
    queryKey: queryKeys.bankReconciliation.pending(sessionId ?? ""),
    enabled: !!sessionId,
    queryFn: async () => {
      const data = await pythonClient.get<SessionPendingApi>(
        `/reconciliation-sessions/${sessionId}/pending`
      )
      return {
        session: mapSession(data.session),
        pendingLines: data.pending_lines.map(mapLine),
        pendingMovements: data.pending_movements.map(mapMovement),
      }
    },
  })
}

export function useSessionSuggestions(sessionId: string | null, enabled: boolean) {
  return useQuery({
    queryKey: queryKeys.bankReconciliation.suggestions(sessionId ?? ""),
    enabled: !!sessionId && enabled,
    queryFn: async (): Promise<MatchSuggestion[]> => {
      const rows = await pythonClient.get<SuggestionApi[]>(
        `/reconciliation-sessions/${sessionId}/suggestions`
      )
      return rows.map(mapSuggestion)
    },
  })
}

export interface MatchGroupApi {
  match_group: string
  matched_at: string
  line_count: number
  movement_count: number
  amount: string | number
}

export function useSessionMatches(sessionId: string | null) {
  return useQuery({
    queryKey: [...queryKeys.bankReconciliation.session(sessionId ?? ""), "matches"],
    enabled: !!sessionId,
    queryFn: async () => {
      const rows = await pythonClient.get<MatchGroupApi[]>(
        `/reconciliation-sessions/${sessionId}/matches`
      )
      return rows.map((r) => ({
        matchGroup: r.match_group,
        matchedAt: r.matched_at,
        lineCount: r.line_count,
        movementCount: r.movement_count,
        amount: Number(r.amount),
      }))
    },
  })
}

// ── Mutations ──────────────────────────────────────────────────────────────────

function useInvalidateReconciliation() {
  const queryClient = useQueryClient()
  return () =>
    queryClient.invalidateQueries({ queryKey: queryKeys.bankReconciliation.all() })
}

export function useImportStatement(bankAccountId: string | null) {
  const invalidate = useInvalidateReconciliation()
  return useMutation({
    mutationFn: async (input: {
      idempotencyKey: string
      fileName: string
      fileHash: string
      lines: NormalizedStatementLine[]
    }) => {
      // v3-api-standards §3/§6.2: Idempotency-Key por header (D4).
      return pythonClient.post<StatementImportResultApi>(
        `/bank-accounts/${bankAccountId}/statement-imports`,
        {
          file_name: input.fileName,
          file_hash: input.fileHash,
          lines: input.lines,
        },
        { "Idempotency-Key": input.idempotencyKey }
      )
    },
    onSuccess: () => invalidate(),
  })
}

export function useOpenSession(bankAccountId: string | null) {
  const invalidate = useInvalidateReconciliation()
  return useMutation({
    mutationFn: async (input: {
      periodFrom: string
      periodTo: string
      statementClosingBalance: string
    }) => {
      return pythonClient.post(
        `/bank-accounts/${bankAccountId}/reconciliation-sessions`,
        {
          period_from: input.periodFrom,
          period_to: input.periodTo,
          statement_closing_balance: input.statementClosingBalance,
        }
      )
    },
    onSuccess: () => invalidate(),
  })
}

export function useCreateMatch(sessionId: string | null) {
  const invalidate = useInvalidateReconciliation()
  return useMutation({
    mutationFn: async (input: { statementLineIds: string[]; bankMovementIds: string[] }) => {
      return pythonClient.post<MatchGroupResultApi>(
        `/reconciliation-sessions/${sessionId}/matches`,
        {
          statement_line_ids: input.statementLineIds,
          bank_movement_ids: input.bankMovementIds,
        }
      )
    },
    onSuccess: () => invalidate(),
  })
}

export function useUndoMatch(sessionId: string | null) {
  const invalidate = useInvalidateReconciliation()
  return useMutation({
    mutationFn: async (input: { matchGroup: string; undoReason: string }) => {
      return pythonClient.post(
        `/reconciliation-sessions/${sessionId}/matches/${input.matchGroup}/undo`,
        { undo_reason: input.undoReason }
      )
    },
    onSuccess: () => invalidate(),
  })
}

export function useCloseSession(sessionId: string | null) {
  const invalidate = useInvalidateReconciliation()
  return useMutation({
    mutationFn: async (input: { closeReason: string | null }) => {
      return pythonClient.post(`/reconciliation-sessions/${sessionId}/close`, {
        close_reason: input.closeReason,
      })
    },
    onSuccess: () => invalidate(),
  })
}

/** "Solo anotar" (V1): cargo del extracto sin contraparte → movimiento manual. */
export function useRegisterManualMovement(bankAccountId: string | null) {
  const invalidate = useInvalidateReconciliation()
  return useMutation({
    mutationFn: async (input: {
      idempotencyKey: string
      amount: string
      movementType: "transfer_in" | "transfer_out" | "manual_adjustment" | "fee" | "tax_debit" | "interest"
      valueDate: string | null
      description: string | null
    }) => {
      // v3-api-standards §3/§6.2: Idempotency-Key por header (D4).
      return pythonClient.post(
        `/bank-accounts/${bankAccountId}/movements`,
        {
          amount: input.amount,
          movement_type: input.movementType,
          value_date: input.valueDate,
          description: input.description,
        },
        { "Idempotency-Key": input.idempotencyKey }
      )
    },
    onSuccess: () => invalidate(),
  })
}
