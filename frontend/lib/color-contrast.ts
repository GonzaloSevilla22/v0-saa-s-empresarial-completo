/**
 * Aritmética de contraste WCAG 2.1 (documentos-marca-empresa D3).
 *
 * Promovida desde `__tests__/lib/token-contrast-aa.test.ts` (su comentario decía
 * "si un segundo consumidor aparece, se promueve a `frontend/lib/`"): el segundo
 * consumidor es el aviso de contraste en vivo de la pestaña "Documentos" de
 * Configuración. El gate de tokens la sigue usando, importada de acá.
 *
 * El cálculo AUTORITATIVO de la paleta de los papeles es el de Python
 * (`backend/services/commercial_documents/palette.py`): el servidor rechaza un
 * acento ilegible (422 `branding_accent_low_contrast`) y el render cae a Neutro.
 * Esto sólo avisa ANTES de guardar. Los dos lados se atan con el fixture
 * `backend/tests/fixtures/document_palette_cases.json`.
 */

export interface Rgb {
  r: number
  g: number
  b: number
}

export const WHITE: Rgb = { r: 255, g: 255, b: 255 }
/** La tinta de los papeles (`#1e293b`, la de la Factura C). */
export const INK: Rgb = { r: 30, g: 41, b: 59 }
/** Contraste mínimo de un acento contra blanco (WCAG 2.1 AA, texto normal). */
export const MIN_ACCENT_CONTRAST = 4.5

const HEX_COLOR = /^#([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i

/** `#rrggbb` (cualquier caso) → canales 0–255; `null` si no tiene esa forma. */
export function hexToRgb(hex: string): Rgb | null {
  const match = HEX_COLOR.exec(hex)
  if (!match) return null
  return { r: parseInt(match[1], 16), g: parseInt(match[2], 16), b: parseInt(match[3], 16) }
}

export function srgbChannelToLinear(channel255: number): number {
  const c = channel255 / 255
  return c <= 0.03928 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4)
}

export function relativeLuminance(rgb: Rgb): number {
  const r = srgbChannelToLinear(rgb.r)
  const g = srgbChannelToLinear(rgb.g)
  const b = srgbChannelToLinear(rgb.b)
  return 0.2126 * r + 0.7152 * g + 0.0722 * b
}

/** WCAG 2.1: (L_claro + 0.05) / (L_oscuro + 0.05). Simétrico. */
export function contrastRatio(a: Rgb, b: Rgb): number {
  const la = relativeLuminance(a)
  const lb = relativeLuminance(b)
  const lighter = Math.max(la, lb)
  const darker = Math.min(la, lb)
  return (lighter + 0.05) / (darker + 0.05)
}

/** El texto —blanco o la tinta— de MAYOR contraste sobre `background` (empate: blanco). */
export function bestTextOn(background: Rgb): Rgb {
  return contrastRatio(WHITE, background) >= contrastRatio(INK, background) ? WHITE : INK
}

/**
 * El contraste como se le muestra a la persona: 2 decimales. Un valor por debajo del
 * mínimo NUNCA se muestra como 4,50 (4,49976 redondea a 4,50 pero se rechaza): el
 * aviso no puede contradecir el rechazo.
 */
export function displayContrast(ratio: number): number {
  const shown = Math.round((ratio + 1e-12) * 100) / 100
  if (ratio < MIN_ACCENT_CONTRAST && shown >= MIN_ACCENT_CONTRAST) return 4.49
  return shown
}

/** ¿Es un `#rrggbb` que se lee sobre blanco (>= 4,5:1)? El umbral se aplica al valor EXACTO. */
export function isValidAccent(hex: string): boolean {
  const rgb = hexToRgb(hex)
  return rgb !== null && contrastRatio(rgb, WHITE) >= MIN_ACCENT_CONTRAST
}
