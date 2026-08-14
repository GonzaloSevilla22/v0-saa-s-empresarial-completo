/**
 * Contacto por WhatsApp de ALIADATA — helper canónico.
 *
 * Única fuente del armado de la URL `wa.me` para TODAS las superficies que
 * ofrecen el canal (hoy: el FAB de la home, el link "Contacto" del footer y
 * el CTA "Hablemos" de la card del tier Empresa). Tener una sola función
 * garantiza que las tres apunten al mismo destino; si mañana cambia la
 * validación, se toca acá y nada más.
 *
 * El mensaje inicial SÍ es por superficie (`plan-empresa-contacto`, D4): el
 * segundo parámetro de `aliadataWhatsAppUrl` tiene como default el mensaje
 * general (`ALIADATA_WHATSAPP_MESSAGE`), así FAB y footer no cambian de
 * comportamiento; la card Empresa pasa `ALIADATA_WHATSAPP_MESSAGE_EMPRESA`
 * para que la conversación llegue ya calificada.
 *
 * El número NO vive acá: llega por la variable de entorno de servidor
 * `ALIADATA_WHATSAPP_PHONE` (la lee `app/page.tsx` y `planes/page.tsx`, cada
 * uno la pasa hacia abajo).
 */

import { buildWhatsAppUrl, normalizeWhatsAppPhone } from "@/lib/phone-utils"

/** Arranca la conversación con contexto, para que el visitante no redacte de cero. */
export const ALIADATA_WHATSAPP_MESSAGE = "Hola ALIADATA 👋 Quiero saber más sobre la plataforma."

/**
 * Mensaje del tier Empresa (`plan-empresa-contacto`): llega ya calificado —
 * la conversación arranca sabiendo que el interés es el tier de contacto
 * directo, no una consulta general.
 */
export const ALIADATA_WHATSAPP_MESSAGE_EMPRESA =
  "Hola ALIADATA 👋 Me interesa el plan Empresa. Quiero que adaptemos el sistema a mi negocio."

/**
 * URL `wa.me` al WhatsApp de ALIADATA con un mensaje inicial, o `null` si el
 * número no está configurado o no normaliza a un móvil argentino válido.
 *
 * `message` es por superficie: default `ALIADATA_WHATSAPP_MESSAGE` preserva
 * el comportamiento de los dos consumidores actuales (FAB y footer) sin
 * tocarlos; una tercera superficie (la card del tier Empresa) pasa su propio
 * mensaje para que la conversación llegue ya calificada.
 *
 * Validar ANTES de armar la URL, no después: `buildWhatsAppUrl` tiene un
 * fallback deliberado que con teléfono inválido devuelve `https://wa.me/?text=…`,
 * que abre el SELECTOR DE CONTACTOS de WhatsApp. Es correcto para su uso
 * original (mandarle un comprobante a un cliente sin teléfono cargado), pero
 * de cara al público sería un bug: el visitante tocaría "escribinos a
 * ALIADATA" y WhatsApp le pediría elegir a quién. Sin número válido, `null` —
 * y la superficie que consuma esto decide su degradación (el FAB, el footer
 * y la card Empresa no se renderizan).
 */
export function aliadataWhatsAppUrl(
  phone: string | null | undefined,
  message: string = ALIADATA_WHATSAPP_MESSAGE,
): string | null {
  const normalized = normalizeWhatsAppPhone(phone)
  if (!normalized) return null
  return buildWhatsAppUrl(normalized, message)
}
