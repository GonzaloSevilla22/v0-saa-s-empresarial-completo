"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── API shapes (snake_case from Python backend) ───────────────────────────────

export interface CustomerAccountMovementApi {
  id: string
  customer_account_id: string
  account_id: string
  amount: string | number
  balance_after: string | number
  movement_type: "sale" | "payment_received" | "credit_note" | "adjustment"
  reference_id: string | null
  created_by: string
  created_at: string
}

export interface CustomerAccountApi {
  id: string
  account_id: string
  client_id: string
  balance: string | number
  created_at: string
  movements: CustomerAccountMovementApi[]
}

export interface PaymentReceivedResult {
  payment_id: string | null
  customer_account_id: string | null
  balance_after: string | number | null
  replayed: boolean
  operation_id: string | null
}

// ── Domain types ──────────────────────────────────────────────────────────────

export interface CustomerAccountMovement {
  id: string
  customerAccountId: string
  accountId: string
  amount: number
  balanceAfter: number
  movementType: "sale" | "payment_received" | "credit_note" | "adjustment"
  referenceId: string | null
  createdBy: string
  createdAt: string
}

export interface CustomerAccount {
  id: string
  accountId: string
  clientId: string
  balance: number
  createdAt: string
  movements: CustomerAccountMovement[]
}

// ── Mappers ───────────────────────────────────────────────────────────────────

function mapMovement(r: CustomerAccountMovementApi): CustomerAccountMovement {
  return {
    id:                r.id,
    customerAccountId: r.customer_account_id,
    accountId:         r.account_id,
    amount:            Number(r.amount),
    balanceAfter:      Number(r.balance_after),
    movementType:      r.movement_type,
    referenceId:       r.reference_id,
    createdBy:         r.created_by,
    createdAt:         r.created_at,
  }
}

function mapAccount(r: CustomerAccountApi): CustomerAccount {
  return {
    id:         r.id,
    accountId:  r.account_id,
    clientId:   r.client_id,
    balance:    Number(r.balance),
    createdAt:  r.created_at,
    movements:  r.movements.map(mapMovement),
  }
}

// ── Error translation ─────────────────────────────────────────────────────────

function translateError(message: string): string {
  if (message.includes("overpayment"))           return "El cobro excede el saldo deudor del cliente."
  if (message.includes("credit_requires_client")) return "Las ventas a crédito requieren un cliente asignado."
  if (message.includes("account_not_found"))     return "Cuenta corriente no encontrada."
  if (message.includes("No autorizado"))         return "No tenés permisos para registrar cobros."
  return message || "Ocurrió un error inesperado."
}

// ── Hooks ─────────────────────────────────────────────────────────────────────

/**
 * Fetch the CustomerAccount for a client (creates it lazily via RPC if absent).
 * GET /clientes/{clientId}/cuenta
 */
export function useCustomerAccount(clientId: string | null) {
  return useQuery({
    queryKey: queryKeys.customerAccounts.byClient(clientId ?? ""),
    queryFn: async (): Promise<CustomerAccount | null> => {
      if (!clientId) return null
      const row = await pythonClient.get<CustomerAccountApi>(
        `/clientes/${clientId}/cuenta`
      )
      return mapAccount(row)
    },
    enabled: !!clientId,
    staleTime: 30 * 1000,
  })
}

/**
 * Register a payment received from a client (cobro).
 * POST /customer-accounts/payments
 * Idempotent by idempotency_key.
 */
export function useRegisterPayment(clientId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({
      idempotencyKey,
      amount,
      referenceSaleId,
    }: {
      idempotencyKey: string
      amount: number
      referenceSaleId?: string
    }): Promise<PaymentReceivedResult> => {
      try {
        return await pythonClient.post<PaymentReceivedResult>(
          "/customer-accounts/payments",
          {
            idempotency_key:   idempotencyKey,
            client_id:         clientId,
            amount:            amount.toString(),
            reference_sale_id: referenceSaleId ?? null,
          }
        )
      } catch (err) {
        throw new Error(translateError((err as Error).message))
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: queryKeys.customerAccounts.byClient(clientId),
      })
    },
  })
}
