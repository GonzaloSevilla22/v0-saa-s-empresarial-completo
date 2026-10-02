/**
 * presupuestos-modulo (D9) — helpers de archivo y compartir de un PDF, en la
 * capa canónica.
 *
 * Nacieron embebidos en `components/ventas/sale-receipt-button.tsx`; se
 * extraen SIN cambiar su comportamiento para que el comprobante de venta, la
 * factura y el menú de compartir de los documentos comerciales (presupuesto
 * hoy, remitos después) usen UNA sola definición.
 *
 * Único cambio de contrato: `sharePdf` devuelve `"cancelled"` cuando el
 * usuario cierra el menú nativo (antes volvía como `"shared"`). El menú de
 * compartir lo necesita para no marcar como enviado un documento que el
 * usuario no mandó; `sale-receipt-button` trata `"cancelled"` igual que antes
 * trataba `"shared"`.
 */
import { buildWhatsAppUrl, normalizeWhatsAppPhone } from "@/lib/phone-utils"

/** Descarga un blob con un `<a download>` y libera la URL después. */
export function downloadBlob(blob: Blob, fileName: string): void {
  const url = URL.createObjectURL(blob)
  const a = document.createElement("a")
  a.href = url
  a.download = fileName
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  setTimeout(() => URL.revokeObjectURL(url), 10_000)
}

export type SharePdfResult = "shared" | "cancelled" | "unsupported"

/**
 * Comparte un PDF por el menú nativo (en el celular el usuario elige WhatsApp y
 * se manda el archivo adjunto).
 *
 * - `shared`: se compartió.
 * - `cancelled`: el usuario cerró el menú; no hay que hacer nada más.
 * - `unsupported`: el dispositivo no puede compartir archivos (o el share
 *   falló, p. ej. iOS) y el caller sigue con su fallback de descarga.
 */
export async function sharePdf(file: File, text: string, title: string): Promise<SharePdfResult> {
  const nav = navigator as Navigator & { canShare?: (d: ShareData) => boolean }
  if (!nav.canShare?.({ files: [file] })) return "unsupported"
  try {
    await nav.share({ files: [file], text, title })
    return "shared"
  } catch (err) {
    if ((err as Error)?.name === "AbortError") return "cancelled"
    return "unsupported"
  }
}

/**
 * Abre WhatsApp con `text` pre-cargado: la conversación directa con `phone` si
 * se normaliza a un número válido, y el selector de contactos si no.
 *
 * Devuelve si había un número válido, para que el caller avise ("no hay número
 * de WhatsApp registrado para este cliente") con su propio mecanismo de aviso.
 */
export function openWhatsAppText(phone: string | null | undefined, text: string): boolean {
  window.open(buildWhatsAppUrl(phone, text), "_blank", "noopener,noreferrer")
  return normalizeWhatsAppPhone(phone) !== null
}
