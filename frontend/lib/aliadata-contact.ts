/**
 * Contacto por WhatsApp de ALIADATA — helper canónico.
 *
 * Única fuente del mensaje inicial y del armado de la URL `wa.me` para TODAS
 * las superficies que ofrecen el canal (hoy: el FAB de la home y el link
 * "Contacto" del footer). Tener una sola función garantiza que ambas apunten
 * al mismo destino con el mismo mensaje; si mañana cambia el mensaje o la
 * validación, se toca acá y nada más.
 *
 * El número NO vive acá: llega por la variable de entorno de servidor
 * `ALIADATA_WHATSAPP_PHONE` (la lee `app/page.tsx` y la pasa hacia abajo).
 */

import { buildWhatsAppUrl, normalizeWhatsAppPhone } from "@/lib/phone-utils"

/** Arranca la conversación con contexto, para que el visitante no redacte de cero. */
export const ALIADATA_WHATSAPP_MESSAGE = "Hola ALIADATA 👋 Quiero saber más sobre la plataforma."

/**
 * URL `wa.me` al WhatsApp de ALIADATA con el mensaje estándar, o `null` si el
 * número no está configurado o no normaliza a un móvil argentino válido.
 *
 * Validar ANTES de armar la URL, no después: `buildWhatsAppUrl` tiene un
 * fallback deliberado que con teléfono inválido devuelve `https://wa.me/?text=…`,
 * que abre el SELECTOR DE CONTACTOS de WhatsApp. Es correcto para su uso
 * original (mandarle un comprobante a un cliente sin teléfono cargado), pero
 * de cara al público sería un bug: el visitante tocaría "escribinos a
 * ALIADATA" y WhatsApp le pediría elegir a quién. Sin número válido, `null` —
 * y la superficie que consuma esto decide su degradación (el FAB no se
 * renderiza; el footer conserva su link inerte).
 */
export function aliadataWhatsAppUrl(phone: string | null | undefined): string | null {
  const normalized = normalizeWhatsAppPhone(phone)
  if (!normalized) return null
  return buildWhatsAppUrl(normalized, ALIADATA_WHATSAPP_MESSAGE)
}
