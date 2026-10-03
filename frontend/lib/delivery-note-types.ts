/**
 * remitos-venta (D11/D13) — tipos del contrato de `/delivery-notes` (snake_case
 * del backend Python) y de los estados del remito.
 *
 * Viven en `lib/` y no en el hook para que las funciones puras
 * (`delivery-note-status`, `delivery-note-share`, `delivery-note-stock`) y los
 * componentes no dependan de `hooks/data/use-delivery-notes.ts`. Nunca `any`:
 * lo que el servidor puede mandar como texto o número (`numeric`) se declara
 * `string | number` y se convierte en el borde de lectura.
 *
 * El payload de detalle es `to_jsonb(delivery_notes)` más los nombres de
 * cliente y sucursal, las líneas y el historial (`_delivery_note_payload`).
 * El remito de VENTA es el único sentido que escribe este change, pero el
 * modelo ya es de los dos sentidos: `direction` viaja en cada fila y el número
 * visible se formatea desde él (`lib/internal-document-number.ts`), nunca con
 * un prefijo fijo.
 */
import type { Paginated } from "@/lib/quote-types"

export type { Paginated }

export const DELIVERY_NOTE_STATUSES = ["issued", "converted", "canceled"] as const

export type DeliveryNoteStatus = (typeof DELIVERY_NOTE_STATUSES)[number]

export type DeliveryNoteDirection = "sale" | "purchase"

// ── Entrada ────────────────────────────────────────────────────────────────────

/** Una línea del remito: siempre de producto (OQ-RV11, sin líneas de servicio). */
export interface DeliveryNoteItemInput {
  product_id: string
  unit_id: string | null
  quantity: number
  /** Precio unitario efectivo (con el descuento adentro), sin redondear. */
  price: number
  subtotal: number
}

export interface CreateDeliveryNoteInput {
  /** Sólo `"sale"` en este change; el backend rechaza cualquier otro valor. */
  direction: "sale"
  client_id: string
  /** Obligatoria: de ahí sale el stock (`delivery_note_branch_required`). */
  branch_id: string
  delivery_address?: string | null
  notes?: string | null
  items: DeliveryNoteItemInput[]
}

/**
 * La edición es un reemplazo completo (D5): `delivery_address`/`notes` en `null`
 * significan vacío, y `revision` es la versión que el usuario cargó
 * (`delivery_note_changed` si cambió mientras editaba).
 */
export interface UpdateDeliveryNoteInput {
  client_id: string
  branch_id: string
  delivery_address: string | null
  notes: string | null
  revision: number
  items: DeliveryNoteItemInput[]
}

/** Anulación (D16): motivo de 3 a 500 caracteres y la revisión que se mostró. */
export interface DeliveryNoteCancelInput {
  reason: string
  revision: number
}

// ── Salida ─────────────────────────────────────────────────────────────────────

export interface DeliveryNoteItemApiRow {
  id: string
  delivery_note_id: string
  product_id: string
  unit_id: string | null
  /** Símbolo de la unidad de la línea (`kg`, `u`), resuelto por el servidor. */
  unit_symbol?: string | null
  quantity: string | number
  price: string | number
  subtotal: string | number
  /**
   * Cantidad normalizada a la unidad base del producto: lo que la línea RETIENE
   * del stock (D1/D4). Es la fuente del retenido, nunca el ledger.
   */
  quantity_base: string | number
  name_snapshot: string | null
  sku_snapshot: string | null
  unit_cost_snapshot: string | number | null
  iva_rate_snapshot: string | number | null
  line_no: number | null
  /** El producto fue dado de baja después de emitir: se conserva lo entregado. */
  product_deleted?: boolean
}

export interface DeliveryNoteHistoryEntry {
  from_status: DeliveryNoteStatus | null
  to_status: DeliveryNoteStatus
  /** Quién hizo la transición; `null` en filas que no la registraron. */
  performed_by: string | null
  /** Instante de la transición (`document_status_history.occurred_at`). */
  occurred_at: string
  reason: string | null
}

export interface DeliveryNoteApiRow {
  id: string
  account_id?: string
  direction: DeliveryNoteDirection
  /** Número interno por cuenta y sentido; `null` sólo en filas sin numerar. */
  number: number | null
  /** El número ya formateado por el servidor (`R-00000012`); `null` sin numerar. */
  number_label?: string | null
  status: DeliveryNoteStatus
  /** Versión del contenido: se incrementa en cada edición. */
  revision: number
  client_id: string | null
  client_name: string | null
  client_phone: string | null
  client_tax_id?: string | null
  /** Nombre del emisor tal como lo imprime el PDF (sólo en el detalle). */
  issuer_name?: string | null
  /** El cliente fue dado de baja después de emitir (D11: hay que elegir otro para editar). */
  client_deleted?: boolean
  branch_id: string
  branch_name: string | null
  /** Día ART de la emisión (`YYYY-MM-DD`): fecha de negocio, no instante. */
  issued_on: string
  delivery_address: string | null
  notes: string | null
  total: string | number
  created_at: string
  created_by: string | null
  updated_at: string | null
  updated_by: string | null
  /** Tanda B: la orden de venta generada al convertir (`converted`), si existe. */
  converted_sales_order_id?: string | null
  converted_operation_id?: string | null
  /** Sólo en la respuesta de la emisión: `true` si la clave ya había emitido este remito. */
  replayed?: boolean
  items: DeliveryNoteItemApiRow[]
  history: DeliveryNoteHistoryEntry[]
}

/** Fila del listado paginado: sin líneas ni historial. */
export interface DeliveryNoteListItem {
  id: string
  direction: DeliveryNoteDirection
  number: number | null
  /** El número ya formateado por el servidor (`R-00000012`); `null` sin numerar. */
  number_label?: string | null
  status: DeliveryNoteStatus
  revision?: number
  client_id: string | null
  client_name: string | null
  client_phone?: string | null
  branch_id: string
  branch_name: string | null
  issued_on: string
  /** Cantidad de líneas del remito. */
  item_count?: number
  total: string | number
  created_at: string
  updated_at: string | null
}

/** Remitos pendientes (`issued`) del mismo recorte del listado, sin importar el estado pedido. */
export interface DeliveryNoteSummary {
  pending_count: number
  pending_total: string | number
}

/** `{items,total,page,pages}` más el resumen de pendientes del encabezado de `/remitos`. */
export interface DeliveryNotePage extends Paginated<DeliveryNoteListItem> {
  summary: DeliveryNoteSummary
}

export interface DeliveryNoteListFilters {
  /** Sin él, el listado trae los dos sentidos (lo usa el guard de baja de sucursal). */
  direction?: DeliveryNoteDirection
  status?: DeliveryNoteStatus
  /** Nombre del cliente o número (`R-12`, `12`, `00000012`). */
  q?: string
  clientId?: string
  branchId?: string
  page?: number
  pageSize?: number
}
