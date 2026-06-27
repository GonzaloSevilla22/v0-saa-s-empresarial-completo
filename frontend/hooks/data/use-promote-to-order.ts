"use client"

/**
 * facturar-venta-manual (D6/D7) — usePromoteToOrder.
 *
 * Mutación React Query para promover una venta legacy a SalesOrder confirmada
 * vía `POST /sales/{operation_id}/promote-to-order`.
 *
 * Comportamiento:
 *   - Al éxito: invalida queries de ventas y salesOrders para que la lista se refresque.
 *   - Idempotente: doble llamada devuelve la orden existente con replayed=true.
 *   - Propaga errores para que el componente los maneje con toasts.
 *
 * Reglas duras:
 *   - NUNCA usar `any` — tipos explícitos.
 *   - Solo llama al pythonClient (backend FastAPI), no a Supabase directamente.
 */

import { useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── API shapes ─────────────────────────────────────────────────────────────────

export interface PromoteToOrderResult {
  sales_order_id:    string
  sale_operation_id: string
  replayed:          boolean
}

// ── Error translation ─────────────────────────────────────────────────────────

function translatePromoteError(message: string): string {
  if (message.includes("operation_not_found"))
    return "Operación de venta no encontrada."
  if (message.includes("unauthorized") || message.includes("Sin permiso"))
    return "No tenés permisos para facturar esta venta."
  if (message.includes("no_branch_found") || message.includes("Conflicto"))
    return "No se encontró una sucursal activa para la cuenta. Configurá una en Ajustes."
  return message || "Error al preparar la venta para facturación."
}

// ── Hook ──────────────────────────────────────────────────────────────────────

/**
 * usePromoteToOrder — promueve una venta legacy (operation_id) a SalesOrder confirmada.
 *
 * Usage:
 *   const promoteMutation = usePromoteToOrder()
 *   const result = await promoteMutation.mutateAsync(operationId)
 *   // result.sales_order_id → pasar a EmitInvoiceButton
 */
export function usePromoteToOrder() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (operationId: string): Promise<PromoteToOrderResult> => {
      try {
        return await pythonClient.post<PromoteToOrderResult>(
          `/sales/${operationId}/promote-to-order`,
          {}
        )
      } catch (err) {
        throw new Error(translatePromoteError((err as Error).message))
      }
    },
    onSuccess: () => {
      // Invalidar ventas y salesOrders para refrescar la lista y los badges
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.all() })
    },
  })
}
