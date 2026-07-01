"use client"

import { useQuery } from "@tanstack/react-query"
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

/**
 * Fetch the account's active bank accounts (for the payment-method bank-account picker).
 * GET /bank-accounts
 */
export function useBankAccounts() {
  return useQuery({
    queryKey: queryKeys.bankAccounts.active(),
    queryFn: async (): Promise<BankAccount[]> => {
      const rows = await pythonClient.get<BankAccountApi[]>("/bank-accounts")
      return rows.map(mapBankAccount)
    },
    staleTime: 5 * 60 * 1000, // 5 min — catalog changes infrequently
  })
}
