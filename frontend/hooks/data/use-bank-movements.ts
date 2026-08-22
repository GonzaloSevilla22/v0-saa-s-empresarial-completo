"use client"

/**
 * Historial de movimientos de una cuenta bancaria (D3 del design,
 * ledger-movement-history) — GET /bank-accounts/{id}/movements, paginado
 * server-side.
 *
 * Función plana (no hook): ver la nota en use-cash-movements.ts —
 * `LedgerMovementsPanel` acumula páginas de forma imperativa ("Ver más"),
 * así que `config.fetchPage` necesita una función invocable directamente.
 */
import { pythonClient } from "@/lib/api/python-client"
import type { BankMovementRow, BankMovementType, Page, ReconciliationStatus } from "@/lib/types"
import type { LedgerFetchParams } from "@/lib/ledger/types"

interface BankMovementApiRow {
  id: string
  bank_account_id: string
  amount: string | number
  balance_after: string | number
  movement_type: BankMovementType
  value_date: string | null
  description: string | null
  created_at: string
  reconciliation_status: ReconciliationStatus
}

function mapRow(r: BankMovementApiRow): BankMovementRow {
  return {
    id:                    r.id,
    bankAccountId:         r.bank_account_id,
    amount:                Number(r.amount),
    balanceAfter:          Number(r.balance_after),
    movementType:          r.movement_type,
    valueDate:             r.value_date,
    description:           r.description,
    createdAt:             r.created_at,
    reconciliationStatus:  r.reconciliation_status,
  }
}

export async function fetchBankMovementsPage(
  bankAccountId: string,
  params: LedgerFetchParams
): Promise<Page<BankMovementRow>> {
  const qs = new URLSearchParams()
  qs.set("page", String(params.page))
  qs.set("size", String(params.size))
  if (params.q) qs.set("q", params.q)
  if (params.from) qs.set("from", params.from)
  if (params.to) qs.set("to", params.to)
  for (const t of params.types ?? []) qs.append("types", t)
  if (params.extra?.status) qs.set("status", params.extra.status)

  const data = await pythonClient.get<{
    items: BankMovementApiRow[]
    total: number
    page: number
    pages: number
  }>(`/bank-accounts/${bankAccountId}/movements?${qs.toString()}`)

  return { ...data, items: data.items.map(mapRow) }
}
