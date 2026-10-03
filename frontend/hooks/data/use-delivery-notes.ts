"use client"

/**
 * remitos-venta (D11/D13) — React Query hooks del remito, sobre el contrato de
 * `/delivery-notes`.
 *
 * Reglas:
 *   - NUNCA `any`: los tipos del contrato viven en `lib/delivery-note-types.ts`.
 *   - Los errores llegan tal cual (`PythonApiError` con su `code` estable):
 *     quien los muestra los traduce con `humanizeOperationError`
 *     (`lib/operation-errors.ts`, contexto `documentLabel: "remito"`); este
 *     módulo no mantiene un segundo mapa.
 *   - El remito MUEVE STOCK al emitirse, al editarse y al anularse, así que
 *     toda mutación invalida `deliveryNotes.*` más `branchStock` y `products`
 *     (lo que muestran los selectores de producto y el desglose por sucursal).
 *     El panel de movimientos de /stock no usa React Query: se recarga al
 *     abrirse y no hay clave de kardex que invalidar.
 *   - Emitir es idempotente por header (`Idempotency-Key`): la clave se genera
 *     una vez por formulario y se resetea en CADA éxito (también en un replay),
 *     para que la próxima emisión sea otra operación. Editar y anular no llevan
 *     clave: las protege la `revision` esperada (un reenvío llega con la versión
 *     vieja y rebota con `delivery_note_changed` sin efectos).
 *   - Sin `useConvertDeliveryNote`: la conversión en venta es de la tanda B.
 */

import { keepPreviousData, useMutation, useQuery, useQueryClient, type QueryClient } from "@tanstack/react-query"
import { pythonClient } from "@/lib/api/python-client"
import { fetchDocumentPdf, type PdfDisposition } from "@/lib/api/document-pdf"
import { useIdempotencyKey } from "@/hooks/use-idempotency-key"
import { queryKeys } from "@/lib/query-keys"
import type {
  CreateDeliveryNoteInput,
  DeliveryNoteApiRow,
  DeliveryNoteCancelInput,
  DeliveryNoteListFilters,
  DeliveryNotePage,
  UpdateDeliveryNoteInput,
} from "@/lib/delivery-note-types"

// ── Invalidación ───────────────────────────────────────────────────────────────

/**
 * Todo lo que una mutación del remito pudo cambiar: el remito (listas y
 * detalle) y el stock — por sucursal (`branchStock`) y el del catálogo
 * (`products`).
 */
function invalidateAfterDeliveryNoteMutation(queryClient: QueryClient): void {
  queryClient.invalidateQueries({ queryKey: queryKeys.deliveryNotes.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.branchStock.all() })
  queryClient.invalidateQueries({ queryKey: queryKeys.products.all() })
}

// ── Listado ────────────────────────────────────────────────────────────────────

/** `/delivery-notes?direction=…&status=…&q=…&client_id=…&branch_id=…&page=…&page_size=…`, sólo con lo que hay. */
function deliveryNotesListPath(filters: DeliveryNoteListFilters): string {
  const params = new URLSearchParams()
  if (filters.direction) params.set("direction", filters.direction)
  if (filters.status) params.set("status", filters.status)
  const q = filters.q?.trim()
  if (q) params.set("q", q)
  if (filters.clientId) params.set("client_id", filters.clientId)
  if (filters.branchId) params.set("branch_id", filters.branchId)
  if (filters.page !== undefined) params.set("page", String(filters.page))
  if (filters.pageSize !== undefined) params.set("page_size", String(filters.pageSize))
  const query = params.toString()
  return query ? `/delivery-notes?${query}` : "/delivery-notes"
}

/**
 * Remitos de la cuenta, paginados `{items,total,page,pages}`.
 * GET /delivery-notes — mantiene la página anterior mientras llega la siguiente.
 * Sin `direction` trae los dos sentidos (lo usa el diálogo de baja de sucursal).
 */
export function useDeliveryNotes(filters: DeliveryNoteListFilters = {}) {
  return useQuery({
    queryKey: queryKeys.deliveryNotes.list(filters),
    queryFn: (): Promise<DeliveryNotePage> =>
      pythonClient.get<DeliveryNotePage>(deliveryNotesListPath(filters)),
    placeholderData: keepPreviousData,
    staleTime: 30 * 1000,
  })
}

/**
 * Un remito con sus líneas y su historial.
 * GET /delivery-notes/{id} — ajeno e inexistente responden igual (404).
 */
export function useDeliveryNote(deliveryNoteId: string | null) {
  return useQuery({
    queryKey: queryKeys.deliveryNotes.detail(deliveryNoteId ?? ""),
    queryFn: (): Promise<DeliveryNoteApiRow> =>
      pythonClient.get<DeliveryNoteApiRow>(`/delivery-notes/${deliveryNoteId}`),
    enabled: !!deliveryNoteId,
    staleTime: 30 * 1000,
  })
}

// ── Escritura ──────────────────────────────────────────────────────────────────

/**
 * Emite un remito de venta: descuenta el stock de la sucursal elegida en la
 * misma transacción (si no alcanza, nada se guarda). POST /delivery-notes.
 *
 * La clave de idempotencia sale de `useIdempotencyKey("delivery-note-create")`
 * y viaja por header (nunca en el cuerpo): un reintento tras una respuesta
 * perdida cae en el replay del servidor y no descuenta dos veces. Se resetea en
 * cada éxito — un replay también lo es: la respuesta trae el remito igual.
 */
export function useCreateDeliveryNote() {
  const queryClient = useQueryClient()
  const { idempotencyKey, resetIdempotencyKey } = useIdempotencyKey("delivery-note-create")

  return useMutation({
    mutationFn: (payload: CreateDeliveryNoteInput): Promise<DeliveryNoteApiRow> =>
      pythonClient.post<DeliveryNoteApiRow>("/delivery-notes", payload, {
        "Idempotency-Key": idempotencyKey,
      }),
    onSuccess: () => {
      resetIdempotencyKey()
      invalidateAfterDeliveryNoteMutation(queryClient)
    },
  })
}

/**
 * Edita un remito pendiente: reemplazo completo, con la `revision` que se
 * cargó. El servidor ajusta el stock sólo en los pares producto-sucursal que
 * cambian y controla el faltante sobre el neto. PUT /delivery-notes/{id} —
 * `delivery_note_changed` (409) si otro usuario lo modificó antes.
 */
export function useUpdateDeliveryNote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({
      deliveryNoteId,
      payload,
    }: {
      deliveryNoteId: string
      payload: UpdateDeliveryNoteInput
    }): Promise<DeliveryNoteApiRow> =>
      pythonClient.put<DeliveryNoteApiRow>(`/delivery-notes/${deliveryNoteId}`, payload),
    onSuccess: () => {
      invalidateAfterDeliveryNoteMutation(queryClient)
    },
  })
}

/**
 * Anula un remito pendiente: exige motivo, repone el stock que retiene y deja
 * el documento `canceled` (sólo admin/owner). POST /delivery-notes/{id}/cancel.
 */
export function useCancelDeliveryNote() {
  const queryClient = useQueryClient()

  return useMutation({
    mutationFn: ({
      deliveryNoteId,
      payload,
    }: {
      deliveryNoteId: string
      payload: DeliveryNoteCancelInput
    }): Promise<DeliveryNoteApiRow> =>
      pythonClient.post<DeliveryNoteApiRow>(`/delivery-notes/${deliveryNoteId}/cancel`, {
        reason: payload.reason.trim(),
        revision: payload.revision,
      }),
    onSuccess: () => {
      invalidateAfterDeliveryNoteMutation(queryClient)
    },
  })
}

// ── PDF ────────────────────────────────────────────────────────────────────────

/**
 * El PDF del remito (`GET /delivery-notes/{id}/pdf`), para cualquier estado.
 * SIN precios por defecto (R2): `showPrices` lo decide cada descarga o envío,
 * no el documento. `null` si la sesión venció y ya se navegó al login;
 * `DocumentPdfError` ante cualquier otra respuesta no exitosa. Lo consume
 * `DocumentShareMenu`.
 */
export function fetchDeliveryNotePdf(
  deliveryNoteId: string,
  disposition: PdfDisposition = "inline",
  showPrices = false,
): Promise<Blob | null> {
  return fetchDocumentPdf(`/delivery-notes/${encodeURIComponent(deliveryNoteId)}/pdf`, {
    disposition,
    show_prices: showPrices ? "true" : "false",
  })
}
