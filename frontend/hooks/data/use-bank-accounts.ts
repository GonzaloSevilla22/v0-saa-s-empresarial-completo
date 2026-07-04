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
  is_active: boolean
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
  isActive: boolean
}

function mapBankAccount(r: BankAccountApi): BankAccount {
  return {
    id:        r.id,
    accountId: r.account_id,
    name:      r.name,
    bankName:  r.bank_name,
    cbu:       r.cbu,
    alias:     r.alias,
    currency:  r.currency,
    isActive:  r.is_active,
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
