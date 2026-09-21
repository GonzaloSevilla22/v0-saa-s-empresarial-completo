/**
 * Regla de ancho del captcha (Cloudflare Turnstile), compartida por las 5
 * superficies que usan `CaptchaWidget` (login, registro, recuperación de
 * contraseña, enlace mágico y reenvío de verificación).
 *
 * Turnstile en `size: "flexible"` mide `width: 100%` con un mínimo duro de
 * 300 px. Las pantallas de auth comparten la misma geometría (`p-4` de página
 * + borde + `p-4` de tarjeta = 65,6 px), así que en un teléfono de 360 px la
 * columna útil es de 294,4 px: el widget no entra. La librería fuerza igual su
 * contenedor a 300 px, alineado a la izquierda, y el widget sobresalía sólo
 * por la derecha (fix/captcha-widget-mobile-overflow, medido en navegador).
 */

/** Ancho mínimo que exige Turnstile en `size: "flexible"`. */
export const TURNSTILE_FLEXIBLE_MIN_WIDTH_PX = 300

/** Ancho fijo de Turnstile en `size: "compact"` (150 × 140). */
export const TURNSTILE_COMPACT_WIDTH_PX = 150

/**
 * Desborde tolerado **por lado** cuando el widget flexible se centra sobre una
 * columna más angosta que su mínimo. 12 px entra con margen en los 16 px de
 * padding de la tarjeta: el widget nunca toca el borde. Más que eso ya se sale
 * de la tarjeta, y ahí conviene `compact`.
 */
export const CAPTCHA_MAX_OVERHANG_PX = 12

export type CaptchaSize = "flexible" | "compact"

/**
 * Elige el tamaño del widget a partir del ancho disponible de su columna.
 *
 * Un ancho no utilizable (0, negativo, NaN) significa "no se pudo medir"
 * —jsdom, contenedor oculto—, no "angosto": se queda en `flexible` para no
 * degradar el widget a ciegas en pantallas anchas.
 */
export function pickCaptchaSize(availableWidthPx: number): CaptchaSize {
  if (!(availableWidthPx > 0)) return "flexible"
  const narrowestFlexible = TURNSTILE_FLEXIBLE_MIN_WIDTH_PX - 2 * CAPTCHA_MAX_OVERHANG_PX
  return availableWidthPx < narrowestFlexible ? "compact" : "flexible"
}
