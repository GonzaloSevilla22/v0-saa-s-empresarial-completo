"use client"

/**
 * C-29 v21-quote-salesorder — React Query hooks para Quote.
 *
 * Reglas duras:
 *   - NUNCA usar `any` — tipos explícitos
 *   - Componentes en PascalCase
 *   - Invalidar queries de ventas/stock tras accept()
 */

import { useQuery, useMutation, useQueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { queryKeys } from "@/lib/query-keys"

// ── API shapes (snake_case del backend Python) ─────────────────────────────────

export type QuoteStatus = "draft" | "sent" | "accepted" | "expired" | "rejected"

export interface QuoteItemApiRow {
  id: string
  quote_id: string
  account_id: string
  product_id: string | null
  unit_id: string | null
  quantity: string | number
  price: string | number
  subtotal: string | number
}

export interface QuoteApiRow {
  id: string
  account_id: string
  branch_id: string | null
  client_id: string | null
  status: QuoteStatus
  valid_until: string | null
  total: string | number
  created_by: string
  created_at: string
  items: QuoteItemApiRow[]
}

export interface AcceptQuoteApiResult {
  sales_order_id: string
  quote_id: string
  status: string
}

// ── Input shapes ──────────────────────────────────────────────────────────────

export interface QuoteItemInput {
  product_id?: string | null
  unit_id?: string | null
  quantity: number
  price: number
  subtotal: number
}

export interface CreateQuoteInput {
  client_id?: string | null
  branch_id?: string | null
  valid_until?: string | null
  items: QuoteItemInput[]
}

// ── Error translation ─────────────────────────────────────────────────────────

function translateQuoteError(message: string): string {
  if (message.includes("quote_invalid_state"))  return "El presupuesto no está en un estado válido para esta operación."
  if (message.includes("quote_expired"))        return "El presupuesto está vencido y no puede aceptarse."
  if (message.includes("quote_not_found"))      return "Presupuesto no encontrado."
  if (message.includes("unauthorized"))         return "No tenés permisos para realizar esta acción."
  if (message.includes("no_branch_found"))      return "No se encontró sucursal activa para la cuenta."
  return message || "Ocurrió un error inesperado."
}

// ── Hooks ─────────────────────────────────────────────────────────────────────

/**
 * Lista los presupuestos de la cuenta.
 * GET /quotes
 */
export function useQuotes() {
  return useQuery({
    queryKey: queryKeys.quotes.lists(),
    queryFn: (): Promise<QuoteApiRow[]> =>
      pythonClient.get<QuoteApiRow[]>("/quotes"),
    staleTime: 30 * 1000,
  })
}

/**
 * Obtiene un presupuesto por id.
 * GET /quotes/{id}
 */
export function useQuote(quoteId: string | null) {
  return useQuery({
    queryKey: queryKeys.quotes.detail(quoteId ?? ""),
    queryFn: (): Promise<QuoteApiRow> =>
      pythonClient.get<QuoteApiRow>(`/quotes/${quoteId}`),
    enabled: !!quoteId,
    staleTime: 30 * 1000,
  })
}

/**
 * Crea un presupuesto en estado draft.
 * POST /quotes
 */
export function useCreateQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (payload: CreateQuoteInput): Promise<QuoteApiRow> => {
      try {
        return pythonClient.post<QuoteApiRow>("/quotes", payload)
      } catch (err) {
        throw new Error(translateQuoteError((err as Error).message))
      }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.all() })
    },
  })
}

/**
 * Transiciona el estado de un presupuesto.
 * POST /quotes/{id}/transition
 * action: "send" | "reject" | "expire"
 */
export function useTransitionQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async ({
      quoteId,
      action,
    }: {
      quoteId: string
      action: "send" | "reject" | "expire"
    }): Promise<QuoteApiRow> => {
      try {
        return await pythonClient.post<QuoteApiRow>(
          `/quotes/${quoteId}/transition`,
          { action }
        )
      } catch (err) {
        throw new Error(translateQuoteError((err as Error).message))
      }
    },
    onSuccess: (_data, variables) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.detail(variables.quoteId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.lists() })
    },
  })
}

/**
 * Acepta un presupuesto y crea un SalesOrder con los mismos ítems.
 * POST /quotes/{id}/accept
 * Invalida quotes y sales-orders al completar.
 */
export function useAcceptQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (quoteId: string): Promise<AcceptQuoteApiResult> => {
      try {
        return await pythonClient.post<AcceptQuoteApiResult>(
          `/quotes/${quoteId}/accept`,
          {}
        )
      } catch (err) {
        throw new Error(translateQuoteError((err as Error).message))
      }
    },
    onSuccess: (_data, quoteId) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.detail(quoteId) })
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.lists() })
      // La aceptación crea una SalesOrder — invalidar la lista de órdenes
      queryClient.invalidateQueries({ queryKey: queryKeys.salesOrders.all() })
    },
  })
}
