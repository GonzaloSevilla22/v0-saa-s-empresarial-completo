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
  movement_type: "sale" | "payment_received" | "payment_received_reversal" | "credit_note" | "adjustment"
  reference_id: string | null
  created_by: string
  created_at: string
  // cobranzas-reverso (D12): derivados del SERVIDOR — nunca reglas de
  // cliente. Ausentes en respuestas que no los resuelven (p.ej. la vista
  // combinada de get_account) → tratados como false por el mapper.
  is_reversible?: boolean
  is_reversal_blocked?: boolean
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

export interface PaymentReversalResult {
  payment_id: string
  reversed: boolean
  account_movement_id: string
  cash_reversal_id: string | null
  bank_reversals: number
}

// ── Domain types ──────────────────────────────────────────────────────────────

export interface CustomerAccountMovement {
  id: string
  customerAccountId: string
  accountId: string
  amount: number
  balanceAfter: number
  movementType: "sale" | "payment_received" | "payment_received_reversal" | "credit_note" | "adjustment"
  referenceId: string | null
  createdBy: string
  createdAt: string
  /** cobranzas-reverso (D12): el movimiento es un cobro cuyo documento
   * sigue vivo — sólo entonces la fila ofrece la acción "Anular". */
  isReversible: boolean
  /** cobranzas-reverso (D12): el cobro tiene movimiento de caja y esa caja
   * no tiene ninguna sesión abierta — bloquea la acción con el motivo,
   * ANTES de intentar (mismo predicado que evalúa el servidor). */
  isReversalBlocked: boolean
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
    isReversible:      r.is_reversible ?? false,
    isReversalBlocked: r.is_reversal_blocked ?? false,
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
  if (message.includes("overpayment"))            return "El cobro excede el saldo deudor del cliente."
  if (message.includes("credit_requires_client"))  return "Las ventas a crédito requieren un cliente asignado."
  // bank-payment-routing C2
  if (message.includes("bank_account_required"))   return "Elegí una cuenta bancaria para este método de pago."
  if (message.includes("bank_account_not_found"))  return "La cuenta bancaria seleccionada no existe."
  if (message.includes("bank_account_inactive"))   return "La cuenta bancaria seleccionada está inactiva."
  if (message.includes("invalid_payment_method"))  return "Método de pago inválido."
  if (message.includes("account_not_found"))       return "Cuenta corriente no encontrada."
  if (message.includes("No autorizado"))           return "No tenés permisos para registrar cobros."
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
      paymentMethod,
      bankAccountId,
      cashSessionId,
    }: {
      idempotencyKey: string
      amount: number
      referenceSaleId?: string
      /** bank-payment-routing C2: {cash,transfer,card,check}. Omitido → default 'cash' del backend. */
      paymentMethod?: string
      /** Requerido cuando paymentMethod es bancario (transfer/card/check). */
      bankAccountId?: string
      /**
       * caja-compras-cobranzas (D2/D5): opt-in de caja. Omitido/null = el
       * cobro no toca caja (no-op en la RPC).
       */
      cashSessionId?: string | null
    }): Promise<PaymentReceivedResult> => {
      try {
        // v3-api-standards §3/§6.2: la clave de idempotencia viaja por el
        // header Idempotency-Key (D4) — el body ya no la incluye.
        return await pythonClient.post<PaymentReceivedResult>(
          "/customer-accounts/payments",
          {
            client_id:         clientId,
            amount:            amount.toString(),
            reference_sale_id: referenceSaleId ?? null,
            ...(paymentMethod ? { payment_method: paymentMethod } : {}),
            ...(bankAccountId ? { bank_account_id: bankAccountId } : {}),
            ...(cashSessionId ? { cash_session_id: cashSessionId } : {}),
          },
          { "Idempotency-Key": idempotencyKey }
        )
      } catch (err) {
        throw new Error(translateError((err as Error).message))
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: queryKeys.customerAccounts.byClient(clientId),
      })
      // caja-compras-cobranzas (task 11.4): el cobro en efectivo puede haber
      // ingresado a la caja — sin esto el arqueo y el historial de /caja
      // quedan stale.
      queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.cashMovements.all() })
    },
  })
}

/**
 * Anula un cobro de cuenta corriente (cobranzas-reverso, task 12.1).
 * DELETE /customer-accounts/payments/{paymentId} — motivo opcional por body.
 *
 * Invalida cuenta corriente + caja + banco + KPIs del dashboard (task 12.3
 * — lección de compras-proveedor-cuenta-corriente: invalidar en TODAS las
 * mutaciones que postean en libros, no sólo en el alta).
 */
export function useReversePaymentReceived(clientId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({
      paymentId,
      reason,
    }: {
      paymentId: string
      reason?: string
    }): Promise<PaymentReversalResult> => {
      try {
        return await pythonClient.delete<PaymentReversalResult>(
          `/customer-accounts/payments/${paymentId}`,
          { reason: reason ?? null },
        )
      } catch (err) {
        throw new Error((err as Error).message)
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: queryKeys.customerAccounts.byClient(clientId),
      })
      queryClient.invalidateQueries({ queryKey: queryKeys.cashSessions.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.cashMovements.all() })
      // El contra-movimiento bancario, si aplica, invalida el saldo de la
      // cuenta bancaria mostrada en /banco.
      queryClient.invalidateQueries({ queryKey: queryKeys.bankAccounts.all() })
      // El KPI "Cobrado" (collected_revenue) deja de contar el cobro
      // anulado por construcción (D2: el documento se borra) — pero el
      // dashboard igual necesita refetchear para dejar de mostrar el valor
      // stale. use-dashboard-kpi-summary.ts no pasa por queryKeys.ts (clave
      // literal): se invalida por el prefijo del array.
      queryClient.invalidateQueries({ queryKey: ["dashboardKpiSummary"] })
    },
  })
}
