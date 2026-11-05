"use client"

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── API shape (snake_case from Python backend) ────────────────────────────────

export interface BankAccountApi {
  id: string
  account_id: string
  name: string
  bank_name: string | null
  cbu: string | null
  alias: string | null
  currency: string
  account_kind: "bank" | "wallet"
  is_active: boolean
  // banco-saldo-segun-libro: Decimal del backend llega como string (o number).
  opening_balance?: string | number
  current_balance?: string | number
  last_movement_date?: string | null
  pending_reconciliation_count?: number
}

// ── Domain type ────────────────────────────────────────────────────────────────

export interface BankAccount {
  id: string
  accountId: string
  name: string
  bankName: string | null
  cbu: string | null
  alias: string | null
  currency: string
  accountKind: "bank" | "wallet"
  isActive: boolean
  /** Saldo inicial de la cuenta (base de cálculo). */
  openingBalance: number
  /** Saldo según libro = saldo inicial + Σ movimientos (calculado por el servidor). */
  currentBalance: number
  lastMovementDate: string | null
  pendingReconciliationCount: number
}

function mapBankAccount(r: BankAccountApi): BankAccount {
  return {
    id:          r.id,
    accountId:   r.account_id,
    name:        r.name,
    bankName:    r.bank_name,
    cbu:         r.cbu,
    alias:       r.alias,
    currency:    r.currency,
    // cuentas-billetera-tipo: fail-open a 'bank' si el backend todavía no
    // manda el campo (mismo criterio que lib/bank-account-kind.ts).
    accountKind: r.account_kind ?? "bank",
    isActive:    r.is_active,
    openingBalance:             Number(r.opening_balance ?? 0),
    currentBalance:             Number(r.current_balance ?? 0),
    lastMovementDate:           r.last_movement_date ?? null,
    pendingReconciliationCount: r.pending_reconciliation_count ?? 0,
  }
}

// ── Create payload (bank-account-crud) ────────────────────────────────────────

export interface BankAccountCreatePayload {
  name: string
  bank_name?: string
  cbu?: string
  alias?: string
  currency?: string
  opening_balance?: number
  opening_date?: string
  account_kind?: "bank" | "wallet"
}

/**
 * Fetch the account's active bank accounts (for the payment-method bank-account picker),
 * plus the createBankAccount mutation (bank-account-crud: alta desde /finanzas/conciliacion).
 * GET /bank-accounts · POST /bank-accounts
 */
export function useBankAccounts() {
  const queryClient = useQueryClient()

  const query = useQuery({
    queryKey: queryKeys.bankAccounts.active(),
    queryFn: async (): Promise<BankAccount[]> => {
      const rows = await pythonClient.get<BankAccountApi[]>("/bank-accounts")
      return rows.map(mapBankAccount)
    },
    staleTime: 5 * 60 * 1000, // 5 min — catalog changes infrequently
  })

  const createBankAccountMutation = useMutation({
    mutationFn: async (payload: BankAccountCreatePayload): Promise<BankAccount> => {
      const row = await pythonClient.post<BankAccountApi>("/bank-accounts", payload)
      return mapBankAccount(row)
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.bankAccounts.all() })
    },
  })

  return {
    data:               query.data,
    isLoading:          query.isLoading,
    isError:            query.isError,
    error:              query.error,
    createBankAccount:  createBankAccountMutation.mutateAsync,
    createBankAccountMutation,
  }
}
