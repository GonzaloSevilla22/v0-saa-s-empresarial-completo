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
): InvoiceDownloadDecision {
  if (!row) {
    return { ok: false, status: 404, error: "Documento no encontrado" }
  }
  if (row.status === "completed") {
    return { ok: false, status: 409, error: "Documento ya fue procesado" }
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
