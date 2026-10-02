/**
 * presupuestos-modulo (D12) — tipos del contrato de `/quotes` (snake_case del
 * backend Python) y de los estados del presupuesto.
 *
 * Viven en `lib/` y no en el hook para que las funciones puras
 * (`quote-lines`, `quote-share`) y los componentes no dependan de
 * `hooks/data/use-quotes.ts`. Nunca `any`: lo que el servidor puede mandar
 * como texto o número (`numeric`) se declara `string | number` y se convierte
 * en el borde de lectura.
 */

export const QUOTE_STATUSES = ["draft", "sent", "accepted", "expired", "rejected"] as const

export type QuoteStatus = (typeof QUOTE_STATUSES)[number]

/** Estados que el usuario puede pedir por `POST /quotes/{id}/transition`. */
export type QuoteTransitionAction = "send" | "reject"

// ── Entrada ────────────────────────────────────────────────────────────────────

/** Una línea del payload `p_items`: de producto, o de servicio (sin `product_id`). */
export interface QuoteItemInput {
  product_id: string | null
  unit_id: string | null
  quantity: number
  /** Precio unitario EFECTIVO (con el descuento adentro), sin redondear. */
  price: number
  subtotal: number
  /** Obligatoria sólo cuando no hay `product_id` (línea de servicio). */
  description?: string
}

export interface CreateQuoteInput {
  client_id: string
  branch_id?: string | null
  /** `null`/omitida = la validez por defecto de la cuenta. */
  valid_until?: string | null
  notes?: string | null
  items: QuoteItemInput[]
}

/**
 * La edición es un reemplazo completo (D5): `valid_until` es obligatoria y no
 * nula, y `revision` es la versión que el usuario cargó (`quote_changed` si
 * cambió mientras editaba).
 */
export interface UpdateQuoteInput {
  client_id: string
  branch_id: string | null
  valid_until: string
  notes: string | null
  revision: number
  items: QuoteItemInput[]
}

// ── Salida ─────────────────────────────────────────────────────────────────────

export interface QuoteItemApiRow {
  id: string
  quote_id: string
  product_id: string | null
  unit_id: string | null
  /** Símbolo de la unidad de la línea (`kg`, `u`), resuelto por el servidor. */
  unit_symbol?: string | null
  quantity: string | number
  price: string | number
  subtotal: string | number
  /** Nombre/descripción congelados al cotizar (la descripción en una línea de servicio). */
  name_snapshot: string | null
  sku_snapshot: string | null
  line_no: number | null
}

export interface QuoteHistoryEntry {
  from_status: QuoteStatus | null
  to_status: QuoteStatus
  performed_by: string
  /** Instante de la transición (`document_status_history.occurred_at`). */
  occurred_at: string
  reason: string | null
}

export interface QuoteApiRow {
  id: string
  /** Número interno por cuenta; `null` sólo en filas anteriores al módulo. */
  number: number | null
  /** `P-00000012`, armado por el servidor. */
  number_label: string | null
  status: QuoteStatus
  /** Versión del contenido: se incrementa en cada edición. */
  revision: number
  client_id: string | null
  client_name: string | null
  client_phone: string | null
  branch_id: string | null
  valid_until: string | null
  notes: string | null
  total: string | number
  sent_at: string | null
  created_at: string
  created_by: string
  updated_at: string | null
  updated_by: string | null
  /** `draft|sent` con `valid_until` pasada, derivado con el día ART. */
  is_expired: boolean
  /** La orden de venta generada al convertir (`accepted`), si existe. */
  sales_order_id: string | null
  /** Nombre del emisor tal como lo imprime el PDF; sólo viene en el detalle. */
  issuer_name?: string | null
  items: QuoteItemApiRow[]
  history: QuoteHistoryEntry[]
}

/** Fila del listado paginado: sin líneas ni historial. */
export interface QuoteListItem {
  id: string
  number: number | null
  number_label: string | null
  status: QuoteStatus
  is_expired: boolean
  client_id: string | null
  client_name: string | null
  client_phone: string | null
  valid_until: string | null
  total: string | number
  created_at: string
  sent_at: string | null
  updated_at: string | null
}

/** Estándar de paginación de la API (`api-standards`). */
export interface Paginated<T> {
  items: T[]
  total: number
  page: number
  pages: number
}

export interface QuoteListFilters {
  status?: QuoteStatus
  clientId?: string
  /** Nombre del cliente o número (`P-12`, `12`, `00000012`). */
  q?: string
  page?: number
  pageSize?: number
}

export interface QuoteSettings {
  default_quote_validity_days: number
}
