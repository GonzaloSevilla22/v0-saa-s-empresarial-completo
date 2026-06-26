"use client"

/**
 * C-29 v21-quote-salesorder — React Query hooks para SalesOrder / quickSale.
 *
 * Reglas duras:
 *   - NUNCA usar `any` — tipos explícitos
 *   - Invalidar queries de ventas y branch_stock tras confirm / quickSale
 *   - cash ⇒ cash_session_id requerido (validado también en el backend)
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── API shapes ─────────────────────────────────────────────────────────────────

export type PaymentMethod = "cash" | "other"
export type SalesOrderStatus = "draft" | "confirmed" | "canceled"

export interface EmitInvoiceInput {
  /** Opcional: UUID del punto de venta. Si se omite, el backend auto-selecciona el único PV activo. */
  point_of_sale_id?: string | null
}

export interface EmitInvoiceResult {
  fiscal_document_id: string
  comprobante_type:   string
  status:             string   // 'pending_cae'
  punto_de_venta:     number | null
  number:             number | null
  sales_order_id:     string | null
}

export interface SalesOrderItemApiRow {
  id: string
  sales_order_id: string
  account_id: string
  product_id: string | null
  unit_id: string | null
  quantity: string | number
  price: string | number
  subtotal: string | number
}

export interface SalesOrderApiRow {
  id: string
  account_id: string
  branch_id: string
  client_id: string | null
  source_quote_id: string | null
  status: SalesOrderStatus
  payment_method: PaymentMethod
  total: string | number
  sale_operation_id: string | null
  fiscal_document_id: string | null
  created_by: string
  created_at: string
  items: SalesOrderItemApiRow[]
}

export interface ConfirmApiResult {
  sales_order_id: string
  operation_id: string
  total: string | number
  fiscal_doc_id: string | null
  replayed: boolean
}

// ── Input shapes ──────────────────────────────────────────────────────────────

export interface SalesOrderItemInput {
  product_id?: string | null
  unit_id?: string | null
  quantity: number
  price: number
  subtotal?: number
}

export interface ConfirmOrderInput {
  idempotency_key: string
  payment_method: PaymentMethod
  /** Requerido cuando payment_method = 'cash' */
  cash_session_id?: string | null
  comprobante_type?: string | null
  point_of_sale_id?: string | null
  branch_id?: string | null
  canal?: string | null
}

export interface QuickSaleInput {
  idempotency_key: string
  client_id?: string | null
  items: SalesOrderItemInput[]
  payment_method: PaymentMethod
  /** Requerido cuando payment_method = 'cash' */
  cash_session_id?: string | null
  comprobante_type?: string | null
  point_of_sale_id?: string | null
  branch_id?: string | null
  canal?: string | null
}

// ── Error translation ─────────────────────────────────────────────────────────

function translateEmitInvoiceError(message: string): string {
  if (message.includes("already_invoiced"))
    return "Esta venta ya tiene un comprobante emitido."
  if (message.includes("order_not_confirmed"))
    return "La venta debe estar confirmada para emitir un comprobante."
  if (message.includes("ri_not_supported") || message.includes("ri_not_supported"))
    return "La facturación A/B para Responsables Inscriptos aún no está disponible."
  if (message.includes("fiscal_profile_not_found"))
    return "No hay perfil fiscal configurado. Configuralo en Ajustes > Fiscal."
  if (message.includes("no_active_point_of_sale"))
    return "Sin puntos de venta activos. Configurá uno en Ajustes > Fiscal."
  if (message.includes("ambiguous_point_of_sale"))
    return "La cuenta tiene varios puntos de venta activos. Seleccioná cuál usar."
  if (message.includes("RECEPTOR_REQUIRED") || message.includes("receptor_required"))
    return "La venta supera el umbral de identificación obligatoria. Asigná un cliente con CUIT."
  return message || "Error al emitir el comprobante."
}

function translateSalesOrderError(message: string): string {
  if (message.includes("stock_insuficiente"))   return "Stock insuficiente para completar la venta."
  if (message.includes("no_open_session"))       return "No hay sesión de caja abierta. Abrí una sesión antes de cobrar en efectivo."
  if (message.includes("cash_requires_session")) return "Ingresá la sesión de caja para cobrar en efectivo."
  if (message.includes("branch_closed"))         return "La sucursal está cerrada."
  if (message.includes("order_not_in_draft"))    return "La orden ya fue confirmada o cancelada."
  if (message.includes("unauthorized"))          return "No tenés permisos para realizar esta acción."
  if (message.includes("no_branch_found"))       return "No se encontró sucursal activa para la cuenta."
  return message || "Ocurrió un error inesperado."
}

// ── Hooks ─────────────────────────────────────────────────────────────────────

/**
 * Lista las órdenes de venta de la cuenta.
 * GET /sales-orders
 */
export function useSalesOrders() {
  return useQuery({
    queryKey: queryKeys.salesOrders.lists(),
    queryFn: (): Promise<SalesOrderApiRow[]> =>
      pythonClient.get<SalesOrderApiRow[]>("/sales-orders"),
    staleTime: 30 * 1000,
  })
}

/**
 * Obtiene una orden de venta por id.
 * GET /sales-orders/{id}
 */
export function useSalesOrder(salesOrderId: string | null) {
  return useQuery({
    queryKey: queryKeys.salesOrders.detail(salesOrderId ?? ""),
    queryFn: (): Promise<SalesOrderApiRow> =>
      pythonClient.get<SalesOrderApiRow>(`/sales-orders/${salesOrderId}`),
    enabled: !!salesOrderId,
    staleTime: 30 * 1000,
  })
}

/**
 * Confirma una SalesOrder existente (hot path transaccional).
 * POST /sales-orders/{id}/confirm
 * Invalida ventas, stock y la orden específica al confirmar.
 */
export function useConfirmSalesOrder() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({
      salesOrderId,
      payload,
    }: {
      salesOrderId: string
      payload: ConfirmOrderInput
    }): Promise<ConfirmApiResult> => {
      try {
        return await pythonClient.post<ConfirmApiResult>(
          `/sales-orders/${salesOrderId}/confirm`,
          payload
        )
      } catch (err) {
        throw new Error(translateSalesOrderError((err as Error).message))
      }
    },
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.detail(variables.salesOrderId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.lists() })
      // Confirmar una venta afecta branch_stock y la lista de ventas legacy
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.branchStock.all() })
    },
  })
}

/**
 * useEmitInvoice — Emite un comprobante AFIP para una SalesOrder confirmada.
 * POST /sales-orders/{id}/emit-invoice
 *
 * facturar-venta-afip (OQ-2/OQ-3):
 *   - Responde 200 con status='pending_cae'.
 *   - Invalida la query de la venta (detail) al éxito para refrescar el badge.
 *   - 409 si la venta ya tiene comprobante (idempotencia D6).
 *   - 403 si el emisor es RI (OQ-1).
 *
 * El tipo de comprobante NO se pasa: el backend lo resuelve (D3).
 */
export function useEmitInvoice(salesOrderId: string) {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (payload: EmitInvoiceInput = {}): Promise<EmitInvoiceResult> => {
      try {
        return await pythonClient.post<EmitInvoiceResult>(
          `/sales-orders/${salesOrderId}/emit-invoice`,
          payload
        )
      } catch (err) {
        throw new Error(translateEmitInvoiceError((err as Error).message))
      }
    },
    onSuccess: () => {
      // Invalidar el detalle de la venta para que el badge y el botón se actualicen
      queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.detail(salesOrderId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.lists() })
    },
  })
}

/**
 * quickSale — Crea + confirma una SalesOrder en un solo paso (POS).
 * POST /sales-orders/quick-sale
 * Invalida ventas, stock y la lista de órdenes al confirmar.
 */
export function useQuickSale() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (payload: QuickSaleInput): Promise<ConfirmApiResult> => {
      try {
        return await pythonClient.post<ConfirmApiResult>(
          "/sales-orders/quick-sale",
          payload
        )
      } catch (err) {
        throw new Error(translateSalesOrderError((err as Error).message))
      }
    },
    onSuccess: () => {
      // La venta confirmada afecta sales, branch_stock y sales_orders
      queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.sales.all() })
      queryClient.invalidateQueries({ queryKey: queryKeys.branchStock.all() })
    },
  })
}
