"use client"

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── API shapes (snake_case from Python backend) ───────────────────────────────

export interface SupplierAccountMovementApi {
  id: string
  supplier_account_id: string
  account_id: string
  amount: string | number
  balance_after: string | number
  movement_type: "purchase" | "payment_made" | "debit_note" | "adjustment"
  reference_id: string | null
  created_by: string
  created_at: string
}

export interface SupplierAccountApi {
  id: string
  account_id: string
  supplier_id: string
  balance: string | number
  created_at: string
  movements: SupplierAccountMovementApi[]
}

export interface PaymentMadeResult {
  payment_id: string | null
  supplier_account_id: string | null
  balance_after: string | number | null
  replayed: boolean
  operation_id: string | null
}

export interface SupplierChargeResult {
  movement_id: string | null
  supplier_account_id: string | null
  balance_after: string | number | null
  replayed: boolean
  operation_id: string | null
}

// ── Domain types ──────────────────────────────────────────────────────────────

export interface SupplierAccountMovement {
  id: string
  supplierAccountId: string
  accountId: string
  amount: number
  balanceAfter: number
  movementType: "purchase" | "payment_made" | "debit_note" | "adjustment"
  referenceId: string | null
  createdBy: string
  createdAt: string
}

export interface SupplierAccount {
  id: string
  accountId: string
  supplierId: string
  balance: number
  createdAt: string
  movements: SupplierAccountMovement[]
}

// ── Mappers ───────────────────────────────────────────────────────────────────

function mapMovement(r: SupplierAccountMovementApi): SupplierAccountMovement {
  return {
    id:                r.id,
    supplierAccountId: r.supplier_account_id,
    accountId:         r.account_id,
    amount:            Number(r.amount),
    balanceAfter:      Number(r.balance_after),
    movementType:      r.movement_type,
    referenceId:       r.reference_id,
    createdBy:         r.created_by,
    createdAt:         r.created_at,
  }
}

function mapAccount(r: SupplierAccountApi): SupplierAccount {
  return {
    id:         r.id,
    accountId:  r.account_id,
    supplierId: r.supplier_id,
    balance:    Number(r.balance),
    createdAt:  r.created_at,
    movements:  r.movements.map(mapMovement),
  }
}

// ── Error translation ─────────────────────────────────────────────────────────

function translateError(message: string): string {
  if (message.includes("overpayment"))            return "El pago excede el saldo deudor con el proveedor."
  // bank-payment-routing C2
  if (message.includes("bank_account_required"))  return "Elegí una cuenta bancaria para este método de pago."
  if (message.includes("bank_account_not_found")) return "La cuenta bancaria seleccionada no existe."
  if (message.includes("bank_account_inactive"))  return "La cuenta bancaria seleccionada está inactiva."
  if (message.includes("invalid_payment_method")) return "Método de pago inválido."
  if (message.includes("account_not_found"))      return "Cuenta corriente del proveedor no encontrada."
  if (message.includes("No autorizado"))          return "No tenés permisos para registrar pagos."
  return message || "Ocurrió un error inesperado."
}

// ── Hooks ─────────────────────────────────────────────────────────────────────

/**
 * Fetch the SupplierAccount for a supplier.
 * GET /proveedores/{supplierId}/cuenta
 */
export function useSupplierAccount(supplierId: string | null) {
  return useQuery({
    queryKey: queryKeys.supplierAccounts.bySupplier(supplierId ?? ""),
    queryFn: async (): Promise<SupplierAccount | null> => {
      if (!supplierId) return null
      const row = await pythonClient.get<SupplierAccountApi>(
        `/proveedores/${supplierId}/cuenta`
      )
      return mapAccount(row)
    },
    enabled: !!supplierId,
    staleTime: 30 * 1000,
  })
}

/**
 * Register a payment made to a supplier (pago).
 * POST /supplier-accounts/payments
 */
export function useRegisterPaymentMade(supplierId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({
      idempotencyKey,
      amount,
      referencePurchaseId,
      paymentMethod,
      bankAccountId,
    }: {
      idempotencyKey: string
      amount: number
      referencePurchaseId?: string
      /** bank-payment-routing C2: {cash,transfer,card,check}. Omitido → default 'cash' del backend. */
      paymentMethod?: string
      /** Requerido cuando paymentMethod es bancario (transfer/card/check). */
      bankAccountId?: string
    }): Promise<PaymentMadeResult> => {
      try {
        return await pythonClient.post<PaymentMadeResult>(
          "/supplier-accounts/payments",
          {
            idempotency_key:       idempotencyKey,
            supplier_id:           supplierId,
            amount:                amount.toString(),
            reference_purchase_id: referencePurchaseId ?? null,
            ...(paymentMethod ? { payment_method: paymentMethod } : {}),
            ...(bankAccountId ? { bank_account_id: bankAccountId } : {}),
          }
        )
      } catch (err) {
        throw new Error(translateError((err as Error).message))
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({
        queryKey: queryKeys.supplierAccounts.bySupplier(supplierId),
      })
    },
  })
}
