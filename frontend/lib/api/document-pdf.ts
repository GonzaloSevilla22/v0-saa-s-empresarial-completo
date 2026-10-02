/**
 * presupuestos-modulo (D9) — fetch binario de un PDF de documento, con sesión,
 * manejo de 401 y de errores RFC 7807. Extraído de `lib/api/fiscal-invoice.ts`
 * para que la factura, el presupuesto y los remitos que vengan compartan UNA
 * implementación.
 *
 * - Encabezados con `getAuthHeaders` (nunca leyendo cookies); un 401 que ya
 *   navegó al login corta devolviendo `null` (mismo idioma que el resto de los
 *   `fetch` a mano: `redirectedOnUnauthorized`).
 * - Los errores RFC 7807 llegan como `DocumentPdfError` con el `code` estable
 *   del backend, el estado HTTP y el cuerpo crudo (`problem`) para que cada
 *   dominio lo traduzca (p. ej. la factura nombra los datos del emisor que
 *   faltan).
 *
 * No usa `python-client` a propósito: ese cliente parsea JSON y estos
 * endpoints devuelven un binario.
 */
import { getAuthHeaders, redirectedOnUnauthorized, tokenFromHeaders } from "@/lib/api/auth-headers"

export type PdfDisposition = "inline" | "attachment"

export type ProblemBody = Record<string, unknown>

const GENERIC_MESSAGE = "No se pudo obtener el documento. Probá de nuevo."

export class DocumentPdfError extends Error {
  readonly code: string
  readonly status: number
  /** Cuerpo RFC 7807 tal como llegó (vacío si no era JSON). */
  readonly problem: ProblemBody

  constructor(code: string, message: string, status: number, problem: ProblemBody = {}) {
    super(message)
    this.name = "DocumentPdfError"
    this.code = code
    this.status = status
    this.problem = problem
  }
}

async function readProblem(response: Response): Promise<ProblemBody> {
  try {
    const body: unknown = await response.json()
    return body && typeof body === "object" ? (body as ProblemBody) : {}
  } catch {
    return {}
  }
}

function toError(status: number, body: ProblemBody): DocumentPdfError {
  const code = typeof body.code === "string" ? body.code : `http_${status}`
  const message =
    typeof body.code === "string" && typeof body.detail === "string" && body.detail
      ? body.detail
      : GENERIC_MESSAGE
  return new DocumentPdfError(code, message, status, body)
}

/**
 * El PDF servido por `GET {path}?{params}`, o `null` si la sesión venció y ya
 * se navegó al login. Levanta `DocumentPdfError` ante cualquier otra respuesta
 * no exitosa.
 */
export async function fetchDocumentPdf(
  path: string,
  params: Record<string, string> = {},
): Promise<Blob | null> {
  const headers = await getAuthHeaders()
  const query = new URLSearchParams(params).toString()
  const url = `${process.env.NEXT_PUBLIC_BACKEND_URL}${path}${query ? `?${query}` : ""}`
  const response = await fetch(url, { method: "GET", headers })
  if (await redirectedOnUnauthorized(response, tokenFromHeaders(headers))) return null
  if (!response.ok) throw toError(response.status, await readProblem(response))
  return response.blob()
}
