/**
 * factura-fiscal-imprimible (D10) — la factura impresa (PDF) de un comprobante
 * autorizado, desde `GET /fiscal/documents/{id}/pdf`.
 *
 * - El transporte (encabezados con `getAuthHeaders`, 401 → `null`, cuerpo RFC
 *   7807) vive en `lib/api/document-pdf.ts` (presupuestos-modulo D9), que
 *   comparten la factura y los documentos comerciales.
 * - Los errores RFC 7807 llegan como `FiscalInvoiceError` con el `code`
 *   estable del backend y un mensaje en castellano; `issuer_data_incomplete`
 *   nombra lo que falta con las mismas etiquetas que la configuración fiscal.
 */
import { DocumentPdfError, fetchDocumentPdf, type ProblemBody } from "@/lib/api/document-pdf"
import { describeMissingIssuerFields } from "@/lib/fiscal-issuer"

export type InvoiceDisposition = "inline" | "attachment"
export type InvoiceCopy = "original" | "duplicado"

export interface FetchInvoiceOptions {
  disposition?: InvoiceDisposition
  copy?: InvoiceCopy
}

export class FiscalInvoiceError extends Error {
  readonly code: string
  readonly missing: string[]

  constructor(code: string, message: string, missing: string[] = []) {
    super(message)
    this.name = "FiscalInvoiceError"
    this.code = code
    this.missing = missing
  }
}

function toError(body: ProblemBody, status: number): FiscalInvoiceError {
  const code = typeof body.code === "string" ? body.code : `http_${status}`
  const missing = Array.isArray(body.missing)
    ? body.missing.filter((m): m is string => typeof m === "string")
    : []
  if (code === "issuer_data_incomplete") {
    return new FiscalInvoiceError(
      code,
      `Para imprimir la factura falta completar ${describeMissingIssuerFields(missing)}.`,
      missing,
    )
  }
  if (code === "invoice_date_unknown") {
    return new FiscalInvoiceError(
      code,
      // Sin promesa de reintento: no hay un proceso automático que la confirme
      // (el backfill lo corre el administrador con el OK del PO).
      "Todavía no se puede imprimir: falta confirmar con ARCA la fecha de este comprobante (es anterior a la factura imprimible; la completa el administrador).",
    )
  }
  if (typeof body.code === "string" && typeof body.detail === "string" && body.detail) {
    return new FiscalInvoiceError(code, body.detail)
  }
  return new FiscalInvoiceError(code, "No se pudo obtener la factura. Probá de nuevo.")
}

/**
 * El PDF de la factura, o `null` si la sesión venció y ya se navegó al login.
 * Levanta `FiscalInvoiceError` ante cualquier otra respuesta no exitosa.
 */
export async function fetchFiscalInvoicePdf(
  documentId: string,
  { disposition = "inline", copy = "original" }: FetchInvoiceOptions = {},
): Promise<Blob | null> {
  try {
    return await fetchDocumentPdf(`/fiscal/documents/${encodeURIComponent(documentId)}/pdf`, {
      disposition,
      copia: copy,
    })
  } catch (err) {
    if (err instanceof DocumentPdfError) throw toError(err.problem, err.status)
    throw err
  }
}
