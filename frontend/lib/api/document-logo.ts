/**
 * documentos-marca-empresa (D8/D10) — transportes BINARIOS del logo de la cuenta.
 *
 *   - `uploadDocumentLogo`: `PUT /document-branding/logo` con el CUERPO CRUDO de la
 *     imagen (no `multipart/form-data`: el backend no usa `python-multipart` para un solo
 *     archivo). El servidor reconoce el formato por el contenido, la valida y la
 *     normaliza; la respuesta trae el descriptor del logo YA normalizado.
 *   - `fetchDocumentLogoDataUri`: `GET /document-branding/logo?v=<huella>` → `data:` URI
 *     validado, para el HTML imprimible (que no puede cargar una URL con sesión). La huella
 *     en la URL hace que un logo nuevo sea una URL nueva (caché de un día en el servidor).
 *
 * No usan `python-client` a propósito (parsea JSON y estos endpoints son binarios). Mismo
 * idioma que `lib/api/document-pdf.ts`: encabezados con `getAuthHeaders` (nunca leyendo
 * cookies), un 401 que ya navegó al login corta con `null`, y los errores RFC 7807 llegan
 * como un error con el `code` estable del backend.
 */
import { getAuthHeaders, getBackendHeaders, redirectedOnUnauthorized, tokenFromHeaders } from "@/lib/api/auth-headers"
import { isSafeLogoDataUri, type LogoDescriptor } from "@/lib/document-branding"

/** Tope de la subida (el servidor corta con 413 por encima). */
export const LOGO_MAX_UPLOAD_BYTES = 2 * 1024 * 1024
const ACCEPTED_TYPES = ["image/png", "image/jpeg", "image/webp"]
const FINGERPRINT = /^[0-9a-f]{64}$/

export class DocumentLogoError extends Error {
  readonly code: string
  readonly status: number

  constructor(code: string, message: string, status: number) {
    super(message)
    this.name = "DocumentLogoError"
    this.code = code
    this.status = status
  }
}

async function readProblem(response: Response): Promise<Record<string, unknown>> {
  try {
    const body: unknown = await response.json()
    return body && typeof body === "object" ? (body as Record<string, unknown>) : {}
  } catch {
    return {}
  }
}

async function toError(response: Response): Promise<DocumentLogoError> {
  const body = await readProblem(response)
  const code = typeof body.code === "string" ? body.code : `http_${response.status}`
  const detail = typeof body.detail === "string" && body.detail ? body.detail : "No se pudo procesar el logo."
  return new DocumentLogoError(code, detail, response.status)
}

function backendUrl(path: string): string {
  return `${process.env.NEXT_PUBLIC_BACKEND_URL}${path}`
}

/**
 * El chequeo previo del archivo elegido, para dar el mensaje ANTES de subir (el servidor
 * vuelve a validar todo por contenido). `null` = puede subirse.
 */
export function validateLogoFile(file: File): string | null {
  if (!ACCEPTED_TYPES.includes(file.type)) return "El logo tiene que ser una imagen PNG, JPEG o WebP."
  if (file.size > LOGO_MAX_UPLOAD_BYTES) return "El logo pesa más de 2 MB. Elegí una imagen más liviana."
  return null
}

/** El mensaje en castellano de un rechazo de la subida (nunca el texto técnico). */
export function logoErrorMessage(error: unknown): string {
  if (error instanceof DocumentLogoError) {
    switch (error.code) {
      case "branding_logo_too_large":
        return "El logo pesa más de 2 MB. Elegí una imagen más liviana."
      case "branding_logo_unsupported_type":
        return "El logo tiene que ser una imagen PNG, JPEG o WebP."
      case "branding_logo_invalid":
        return "La imagen está dañada o no se pudo leer. Probá con otro archivo."
      case "branding_logo_too_heavy":
        return "El logo pesa demasiado aun reducido. Probá con una imagen más simple o más chica."
      default:
        if (error.status === 403) return "Sólo el dueño o un administrador de la cuenta puede cambiar el logo."
    }
  }
  return "No se pudo subir el logo. Probá de nuevo."
}

/**
 * Sube el logo. Devuelve el descriptor del logo normalizado, o `null` si la sesión venció y
 * ya se navegó al login. Levanta `DocumentLogoError` ante cualquier otra respuesta no exitosa.
 */
export async function uploadDocumentLogo(file: Blob): Promise<LogoDescriptor | null> {
  // multiusuario-operativo (D6): la subida es una ESCRITURA sobre la marca de la cuenta
  // — declara la cuenta que la pantalla muestra, para que una pestaña desfasada reciba el
  // 409 en vez de pisar el logo de la cuenta nueva.
  const headers = await getBackendHeaders({ "Content-Type": file.type || "application/octet-stream" })
  const response = await fetch(backendUrl("/document-branding/logo"), { method: "PUT", headers, body: file })
  if (await redirectedOnUnauthorized(response, tokenFromHeaders(headers))) return null
  if (!response.ok) throw await toError(response)
  const body = (await response.json().catch(() => null)) as { logo?: Partial<LogoDescriptor> } | null
  const logo = body?.logo
  if (
    !logo || typeof logo.sha256 !== "string" || typeof logo.mime !== "string" ||
    typeof logo.width !== "number" || typeof logo.height !== "number"
  ) {
    throw new DocumentLogoError("invalid_response", "La respuesta del servidor no tiene el logo.", response.status)
  }
  return { sha256: logo.sha256, mime: logo.mime, width: logo.width, height: logo.height }
}

function toBase64(bytes: Uint8Array): string {
  let binary = ""
  const chunk = 0x8000
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk))
  }
  return btoa(binary)
}

/**
 * El logo de la cuenta como `data:` URI (PNG/JPEG validado), o `null` si no hay logo, la
 * sesión venció, la huella tiene forma rara o el contenido no es una imagen PNG/JPEG.
 */
export async function fetchDocumentLogoDataUri(sha256: string): Promise<string | null> {
  if (!FINGERPRINT.test(sha256)) return null
  const headers = await getAuthHeaders()
  const response = await fetch(backendUrl(`/document-branding/logo?v=${sha256}`), { method: "GET", headers })
  if (await redirectedOnUnauthorized(response, tokenFromHeaders(headers))) return null
  if (response.status === 404) return null
  if (!response.ok) throw await toError(response)
  const blob = await response.blob()
  if (blob.type !== "image/png" && blob.type !== "image/jpeg") return null
  const uri = `data:${blob.type};base64,${toBase64(new Uint8Array(await blob.arrayBuffer()))}`
  return isSafeLogoDataUri(uri) ? uri : null
}
