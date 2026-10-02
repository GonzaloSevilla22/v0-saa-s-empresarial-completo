"use client"

/**
 * presupuestos-modulo (D12) — React Query hooks del presupuesto, sobre el
 * contrato nuevo de `/quotes` (reescribe los hooks huérfanos de C-29).
 *
 * Reglas:
 *   - NUNCA `any`: los tipos del contrato viven en `lib/quote-types.ts`.
 *   - Los errores llegan tal cual (`PythonApiError` con su `code` estable):
 *     quien los muestra los traduce con `humanizeOperationError`
 *     (`lib/operation-errors.ts`); este módulo no mantiene un segundo mapa.
 *   - Sin `useAcceptQuote`: `POST /quotes/{id}/accept` se retiró (dejaba un
 *     presupuesto `accepted` con una orden `draft` invisible). Pasar a venta es
 *     `useConvertQuote`, la conversión atómica.
 *   - Toda mutación invalida `quotes.*` (listas y detalle son del mismo
 *     documento); las que cambian el stock, la caja o el banco usan además
 *     `invalidateAfterSale`.
 */

import { keepPreviousData, useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useAuth } from "@/contexts/auth-context"
import { pythonClient } from "@/lib/api/python-client"
import { fetchDocumentPdf, type PdfDisposition } from "@/lib/api/document-pdf"
import { queryKeys } from "@/lib/query-keys"
import { invalidateAfterSale } from "@/lib/query-invalidation"
import type {
  CreateQuoteInput,
  Paginated,
  QuoteApiRow,
  QuoteConvertInput,
  QuoteConvertResult,
  QuoteListFilters,
  QuoteListItem,
  QuoteTransitionAction,
  UpdateQuoteInput,
} from "@/lib/quote-types"

// ── Listado ────────────────────────────────────────────────────────────────────

/** `/quotes?status=…&client_id=…&q=…&page=…&page_size=…`, sólo con lo que hay. */
function quotesListPath(filters: QuoteListFilters): string {
  const params = new URLSearchParams()
  if (filters.status) params.set("status", filters.status)
  if (filters.clientId) params.set("client_id", filters.clientId)
  const q = filters.q?.trim()
  if (q) params.set("q", q)
  if (filters.page !== undefined) params.set("page", String(filters.page))
  if (filters.pageSize !== undefined) params.set("page_size", String(filters.pageSize))
  const query = params.toString()
  return query ? `/quotes?${query}` : "/quotes"
}

/**
 * Presupuestos de la cuenta, paginados `{items,total,page,pages}`.
 * GET /quotes — mantiene la página anterior mientras llega la siguiente.
 */
export function useQuotes(filters: QuoteListFilters = {}) {
  return useQuery({
    queryKey: queryKeys.quotes.list(filters),
    queryFn: (): Promise<Paginated<QuoteListItem>> =>
      pythonClient.get<Paginated<QuoteListItem>>(quotesListPath(filters)),
    placeholderData: keepPreviousData,
    staleTime: 30 * 1000,
  })
}

/**
 * Un presupuesto con sus líneas y su historial.
 * GET /quotes/{id}
 */
export function useQuote(quoteId: string | null) {
  return useQuery({
    queryKey: queryKeys.quotes.detail(quoteId ?? ""),
    queryFn: (): Promise<QuoteApiRow> => pythonClient.get<QuoteApiRow>(`/quotes/${quoteId}`),
    enabled: !!quoteId,
    staleTime: 30 * 1000,
  })
}

// ── Escritura ──────────────────────────────────────────────────────────────────

/**
 * Crea un presupuesto en `draft` (no mueve stock ni caja).
 * POST /quotes
 */
export function useCreateQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (payload: CreateQuoteInput): Promise<QuoteApiRow> =>
      pythonClient.post<QuoteApiRow>("/quotes", payload),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.all() })
    },
  })
}

/**
 * Edita un presupuesto: reemplazo completo, con la `revision` que se cargó.
 * PUT /quotes/{id} — `quote_changed` (409) si otro usuario lo modificó antes.
 * Editar un `expired`/`rejected` lo reabre a `draft`.
 */
export function useUpdateQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({ quoteId, payload }: { quoteId: string; payload: UpdateQuoteInput }): Promise<QuoteApiRow> =>
      pythonClient.put<QuoteApiRow>(`/quotes/${quoteId}`, payload),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.all() })
    },
  })
}

/**
 * Marca como enviado (`send`, idempotente) o rechaza (`reject`, con motivo
 * opcional). `accepted` va sólo por la conversión y `expired` sólo por el barrido.
 * POST /quotes/{id}/transition
 */
export function useTransitionQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({
      quoteId,
      action,
      reason,
    }: {
      quoteId: string
      action: QuoteTransitionAction
      reason?: string
    }): Promise<QuoteApiRow> => {
      const motive = reason?.trim()
      return pythonClient.post<QuoteApiRow>(
        `/quotes/${quoteId}/transition`,
        motive ? { action, reason: motive } : { action },
      )
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.all() })
    },
  })
}

/**
 * Elimina un borrador nunca enviado.
 * DELETE /quotes/{id} — `quote_not_deletable` (409) en cualquier otro caso.
 */
export function useDeleteQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: (quoteId: string): Promise<void> => pythonClient.delete<void>(`/quotes/${quoteId}`),
    onSuccess: (_data, quoteId) => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.lists() })
      // El detalle de un presupuesto que ya no existe no se vuelve a pedir.
      queryClient.removeQueries({ queryKey: queryKeys.quotes.detail(quoteId) })
    },
  })
}

/**
 * Convierte el presupuesto en venta, de forma atómica (descuenta stock, mueve
 * caja/banco/cuenta corriente y deja la orden `confirmed`; cualquier fallo
 * revierte todo). POST /quotes/{id}/convert
 *
 * La clave de idempotencia la pone quien llama (el diálogo, con
 * `useIdempotencyKey("quote-convert:" + quoteId)`) y viaja por header: así una
 * respuesta perdida de la conversión de A no contamina la de B. Se invalida
 * `quotes.*` más todo lo que toca una venta (`invalidateAfterSale`), también en
 * el replay: la venta ya existe y las pantallas tienen que verla.
 */
export function useConvertQuote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({
      quoteId,
      payload,
      idempotencyKey,
    }: {
      quoteId: string
      payload: QuoteConvertInput
      idempotencyKey: string
    }): Promise<QuoteConvertResult> =>
      pythonClient.post<QuoteConvertResult>(`/quotes/${quoteId}/convert`, payload, {
        "Idempotency-Key": idempotencyKey,
      }),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quotes.all() })
      invalidateAfterSale(queryClient)
    },
  })
}

// ── Validez por defecto de la cuenta ──────────────────────────────────────────

interface QuoteSettingsRaw {
  default_quote_validity_days: number
}

export interface QuoteSettingsView {
  defaultQuoteValidityDays: number
}

/** GET /settings/quotes — días de validez con que nace un presupuesto sin fecha. */
export function useQuoteSettings() {
  const { user } = useAuth()
  const accountId = user?.accountId ?? null

  return useQuery<QuoteSettingsView>({
    queryKey: queryKeys.quoteSettings.get(accountId ?? ""),
    queryFn: async (): Promise<QuoteSettingsView> => {
      const raw = await pythonClient.get<QuoteSettingsRaw>("/settings/quotes")
      return { defaultQuoteValidityDays: raw.default_quote_validity_days }
    },
    enabled: !!accountId,
    staleTime: 60 * 1000,
  })
}

/** PATCH /settings/quotes — sólo owner/admin; 1..365 (422 antes de la base). */
export function useUpdateQuoteSettings() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: async (days: number): Promise<QuoteSettingsView> => {
      const raw = await pythonClient.patch<QuoteSettingsRaw>("/settings/quotes", {
        default_quote_validity_days: days,
      })
      return { defaultQuoteValidityDays: raw.default_quote_validity_days }
    },
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: queryKeys.quoteSettings.all() })
    },
  })
}

// ── PDF ────────────────────────────────────────────────────────────────────────

/**
 * El PDF del presupuesto (`GET /quotes/{id}/pdf`), para cualquier estado.
 * `null` si la sesión venció y ya se navegó al login; `DocumentPdfError` ante
 * cualquier otra respuesta no exitosa. Lo consume `DocumentShareMenu`.
 */
export function fetchQuotePdf(quoteId: string, disposition: PdfDisposition = "inline"): Promise<Blob | null> {
  return fetchDocumentPdf(`/quotes/${encodeURIComponent(quoteId)}/pdf`, { disposition })
}
