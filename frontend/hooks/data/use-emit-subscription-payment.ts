"use client"

/**
 * v22-afip-delegation-billing — useEmitSubscriptionPayment
 *
 * Mutation hook para POST /fiscal/documents/emit-subscription-payment.
 * Emite una Factura C para un pago de suscripción SaaS (flujo admin Aliadata).
 *
 * Idempotency: el backend devuelve already_emitted=true si el recibo ya fue
 * facturado; el hook expone el resultado para que el caller actualice el estado
 * de la fila sin mostrar error.
 *
 * También expone useGetFiscalDocByReceipt para la carga inicial de la página:
 * el admin ve el badge en lugar del botón para recibos ya facturados.
 *
 * Design ref: v22 admin-subscription-invoicing — PO sign-off 2026-06-24.
 *
 * Reglas duras:
 *   - NUNCA usar `any`
 *   - NUNCA emitir automáticamente — el admin debe confirmar explícitamente
 *   - translateEmitError reutilizado para DELEGATION_NOT_AUTHORIZED
 */

import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"
import { translateEmitError } from "@/hooks/data/use-emit-comprobante"
import type { FiscalDocumentStatus } from "@/components/fiscal/FiscalDocumentBadge"

// ── Types ─────────────────────────────────────────────────────────────────────

/** AFIP DocTipo: 80 = CUIT, 96 = DNI */
export type ReceptorDocTipo = 80 | 96

export interface EmitSubscriptionPaymentInput {
  receipt_id: string
  point_of_sale_id?: string | null
  receptor_doc_tipo: ReceptorDocTipo
  receptor_doc_nro: string
}

export interface EmitSubscriptionPaymentResult {
  fiscal_document_id: string
  status: FiscalDocumentStatus
  comprobante_type: string
  total: number
  cae?: string | null
  cae_due_date?: string | null
  subscription_payment_id?: string | null
  already_emitted?: boolean
}

export interface FiscalDocByReceiptResult {
  id: string
  status: FiscalDocumentStatus
  comprobante_type: string
  total: number
  cae?: string | null
  cae_due_date?: string | null
  subscription_payment_id?: string | null
}

// ── Hook: emit ────────────────────────────────────────────────────────────────

/**
 * Emite una Factura C para un pago de suscripción.
 * Solo el admin de plataforma puede usar este hook.
 * El backend valida el rol admin server-side.
 */
export function useEmitSubscriptionPayment() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (
      input: EmitSubscriptionPaymentInput,
    ): Promise<EmitSubscriptionPaymentResult> => {
      try {
        return await pythonClient.post<EmitSubscriptionPaymentResult>(
          "/fiscal/documents/emit-subscription-payment",
          input,
        )
      } catch (err: unknown) {
        throw new Error(translateEmitError((err as Error).message ?? ""))
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.fiscalDocuments.all() })
    },
  })
}

// ── Hook: get by receipt ──────────────────────────────────────────────────────

/**
 * Consulta si un recibo de pago ya tiene un comprobante fiscal emitido.
 * Retorna null si no tiene; el objeto si sí.
 * Usado en page load para mostrar badge en lugar del botón.
 */
export function useGetFiscalDocByReceipt(receiptId: string, enabled = true) {
  const query = useQuery({
    queryKey: ["fiscalDocByReceipt", receiptId],
    queryFn: async (): Promise<FiscalDocByReceiptResult | null> => {
      try {
        return await pythonClient.get<FiscalDocByReceiptResult | null>(
          `/fiscal/documents/by-receipt/${receiptId}`,
        )
      } catch (err: unknown) {
        const message = err instanceof Error ? err.message : String(err)
        // 404 = sin comprobante → normal, retornar null
        if (message.includes("404")) return null
        throw err
      }
    },
    enabled: enabled && Boolean(receiptId),
    staleTime: 60 * 1000, // 1 min — el estado puede cambiar pending→authorized
  })

  return {
    fiscalDoc: query.data ?? null,
    isLoading: query.isLoading,
    isError:   query.isError,
  }
}
