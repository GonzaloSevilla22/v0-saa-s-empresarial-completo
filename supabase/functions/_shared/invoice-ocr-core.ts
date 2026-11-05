// Núcleo puro de la Edge Function invoice-ocr — auth-hardening-jwt-cookies
// Parte A (grupo 7, D13).
//
// El handler (invoice-ocr/index.ts, Deno.serve) cablea las dependencias
// reales (cliente con el JWT del usuario, cliente de service role, OpenAI);
// la DECISIÓN de qué objeto se descarga vive acá y se prueba con vitest
// (frontend/__tests__/invoice-ocr-core.test.ts) — el único arnés de Edge
// Functions que tiene este repo (precedente: _shared/ai-estadisticas-core.ts).
//
// Invariante que este módulo existe para sostener (D13):
//
//   El objeto que se descarga con SERVICE_ROLE_KEY sale de la FILA de
//   invoice_documents ya autorizada por `user_id`, NUNCA del body del
//   request. Antes se autorizaba `document_id` contra `user_id` y después se
//   descargaba el `storage_path` que había mandado el cliente — un confused
//   deputy de una línea, con una policy de storage que habría permitido el
//   abuso (20260510215934_invoice_ocr_system.sql:57-61) y compensado sólo por
//   oscuridad (un path con UUID de 122 bits).
//
//   El campo `storage_path` del body se sigue ACEPTANDO por compatibilidad
//   —el caller vivo lo manda (frontend/lib/services/invoiceOcrService.ts:117-119)—
//   pero no llega a salir de `parseInvoiceOcrRequest`: no hay forma de que el
//   handler lo use por accidente.
//
// TS puro, sin `Deno.*` a nivel módulo: deployable a Deno y testeable.

/** Las columnas de `invoice_documents` que la decisión necesita. */
export interface InvoiceDocumentRow {
  id: string
  mime_type: string | null
  status: string | null
  /** La única fuente del objeto a descargar. */
  storage_path: string | null
  /** Última escritura de la fila: mide el candado de doble clic de `processing`. */
  updated_at?: string | null
}

/**
 * El body tal como llega. `storage_path` está declarado para documentar que se
 * acepta; no se lee en ninguna decisión.
 */
export interface InvoiceOcrRequestBody {
  document_id?: unknown
  storage_path?: unknown
}

export type ParsedInvoiceOcrRequest =
  | { ok: true; documentId: string }
  | { ok: false; status: number; error: string }

export type InvoiceDownloadDecision =
  | { ok: true; storagePath: string; mimeType: string }
  | { ok: false; status: number; error: string }

/** El default histórico del handler cuando la fila no declara mime_type. */
const DEFAULT_MIME_TYPE = "image/jpeg"

// ─── v31-ia-ratelimit-budget — techo de costo POR LLAMADA (D4) ────────────────
// El techo TOTAL es llamadas × costo por llamada: la palanca es la cuota y la
// ráfaga (rpc_reserve_ai_usage). Estas constantes acotan el costo de CADA
// llamada: OpenAI reescala la imagen a un máximo fijo de tiles, así que los
// bytes protegen memoria y latencia, y `max_tokens` acota la salida.

/** Tope de la imagen descargada: 6 MiB (OQ-6), medido sobre los bytes reales. */
export const MAX_INVOICE_IMAGE_BYTES = 6 * 1024 * 1024
/** Modelos admitidos para `INVOICE_AI_MODEL` (allow-list). */
export const OCR_ALLOWED_MODELS: readonly string[] = ["gpt-4o-mini", "gpt-4o"]
/** gpt-4o-mini: visión desde ago-2024, ~10x más barato que gpt-4o. */
export const OCR_DEFAULT_MODEL = "gpt-4o-mini"
export const OCR_MAX_OUTPUT_TOKENS = 2000
/** `high` se conserva (OQ-7): la legibilidad de los ítems lo necesita. */
export const OCR_IMAGE_DETAIL = "high"
export const OCR_TIMEOUT_MS = 55_000
/**
 * Una fila en `processing` más reciente que esto responde 409. Es un candado
 * contra el doble clic, NO el control de abuso: el dueño puede reescribir
 * `status` por PostgREST; el abuso lo frena el contador del usuario.
 */
export const OCR_PROCESSING_LOCK_MS = 90_000

export type ImageBudgetDecision =
  | { ok: true }
  | { ok: false; status: number; error: string }

/**
 * Techo de bytes sobre el objeto DESCARGADO (no sobre `file_size_bytes`, que lo
 * declara el cliente). Un objeto vacío es 422: no hay nada que leer y no debe
 * consumir cupo.
 */
export function checkInvoiceImageBudget(byteLength: number): ImageBudgetDecision {
  if (byteLength <= 0) {
    return { ok: false, status: 422, error: "El archivo está vacío. Subí la foto de la factura de nuevo." }
  }
  if (byteLength > MAX_INVOICE_IMAGE_BYTES) {
    return { ok: false, status: 413, error: "La imagen supera 6 MB. Sacá la foto de nuevo o recortala." }
  }
  return { ok: true }
}

export interface OcrModelResolution {
  model: string
  /** Presente cuando el valor del entorno se ignoró; el handler lo loguea. */
  warning?: string
}

/** Resuelve el modelo contra la allow-list; fuera de la lista (o vacío) = default + aviso. */
export function resolveOcrModel(envValue: string | null | undefined): OcrModelResolution {
  const value = typeof envValue === "string" ? envValue.trim() : ""
  if (value && OCR_ALLOWED_MODELS.includes(value)) return { model: value }
  return {
    model: OCR_DEFAULT_MODEL,
    warning: `INVOICE_AI_MODEL=${JSON.stringify(envValue ?? null)} fuera de la allow-list (${OCR_ALLOWED_MODELS.join(", ")}); se usa ${OCR_DEFAULT_MODEL}`,
  }
}

const BASE64_CHUNK = 32 * 1024

/**
 * base64 por bloques de 32 KiB y un solo btoa. `String.fromCharCode(...bytes)`
 * expande un argumento por byte y revienta con RangeError en imágenes grandes.
 */
export function encodeBase64Chunked(bytes: Uint8Array): string {
  let binary = ""
  for (let i = 0; i < bytes.length; i += BASE64_CHUNK) {
    binary += String.fromCharCode(...bytes.subarray(i, i + BASE64_CHUNK))
  }
  return btoa(binary)
}

function nonEmptyString(value: unknown): string | null {
  if (typeof value !== "string") return null
  const trimmed = value.trim()
  return trimmed.length > 0 ? trimmed : null
}

/**
 * Valida el body. Sólo `document_id` es requerido: `storage_path` se acepta
 * por compatibilidad y deliberadamente NO viaja en el resultado — dejó de ser
 * requerido porque dejó de tener efecto, así que un caller futuro puede
 * omitirlo sin recibir un 400 por un campo que nadie lee.
 */
export function parseInvoiceOcrRequest(body: InvoiceOcrRequestBody | null | undefined): ParsedInvoiceOcrRequest {
  const documentId = nonEmptyString(body?.document_id)
  if (!documentId) {
    return { ok: false, status: 400, error: "Falta document_id" }
  }
  return { ok: true, documentId }
}

/**
 * Resuelve el objeto a descargar a partir de la fila YA autorizada (el SELECT
 * que la trajo filtra por `user_id`). `body` se recibe para que la firma
 * documente que el campo del cliente está disponible y aun así no se usa.
 *
 * Fail-closed: una fila sin `storage_path` es 404, nunca un repliegue al valor
 * del body — ese repliegue sería exactamente el agujero que este módulo cierra.
 */
export function resolveInvoiceDownload(
  row: InvoiceDocumentRow | null | undefined,
  _body: InvoiceOcrRequestBody,
  now: number = Date.now(),
): InvoiceDownloadDecision {
  if (!row) {
    return { ok: false, status: 404, error: "Documento no encontrado" }
  }
  if (row.status === "completed") {
    return { ok: false, status: 409, error: "Documento ya fue procesado" }
  }
  // Candado de doble clic (D4): una lectura en curso reciente no se pisa. Pasados
  // OCR_PROCESSING_LOCK_MS (el timeout de OpenAI es menor) la fila está colgada y se reintenta.
  if (row.status === "processing" && row.updated_at) {
    const updatedAt = Date.parse(row.updated_at)
    if (Number.isFinite(updatedAt) && now - updatedAt < OCR_PROCESSING_LOCK_MS) {
      return { ok: false, status: 409, error: "La factura ya se está leyendo" }
    }
  }
  const storagePath = nonEmptyString(row.storage_path)
  if (!storagePath) {
    return { ok: false, status: 404, error: "Documento no encontrado" }
  }
  return {
    ok: true,
    storagePath,
    mimeType: nonEmptyString(row.mime_type) ?? DEFAULT_MIME_TYPE,
  }
}
