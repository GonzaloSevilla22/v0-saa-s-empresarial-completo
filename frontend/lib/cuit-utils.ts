/**
 * Validación de CUIT/DNI argentinos (C-22 v20-fiscal-identity-clients).
 *
 * - CUIT: formato NN-NNNNNNNN-N + dígito verificador módulo 11
 *   (pesos 5,4,3,2,7,6,5,4,3,2; dígito = 11 - (suma % 11), con 11→0 y 10→9).
 * - DNI: 7 u 8 dígitos, se acepta como identificador sin verificación.
 */

const CUIT_REGEX = /^(\d{2})-(\d{8})-(\d)$/
const DNI_REGEX = /^\d{7,8}$/
const CUIT_WEIGHTS = [5, 4, 3, 2, 7, 6, 5, 4, 3, 2]

export const CUIT_FORMAT_HINT = "Formato CUIT: 20-12345678-6 — o DNI de 7/8 dígitos"

/** ¿El valor tiene forma de CUIT (NN-NNNNNNNN-N)? No verifica el dígito. */
export function isCuitFormat(value: string): boolean {
  return CUIT_REGEX.test(value.trim())
}

/** ¿Es un CUIT válido? Formato + dígito verificador módulo 11. */
export function isValidCuit(value: string): boolean {
  const match = value.trim().match(CUIT_REGEX)
  if (!match) return false
  const digits = (match[1] + match[2]).split("").map(Number)
  const sum = digits.reduce((acc, digit, i) => acc + digit * CUIT_WEIGHTS[i], 0)
  let check = 11 - (sum % 11)
  if (check === 11) check = 0
  if (check === 10) check = 9
  return check === Number(match[3])
}

/** ¿Es un identificador fiscal aceptable? CUIT válido o DNI de 7/8 dígitos. */
export function isValidTaxId(value: string): boolean {
  const trimmed = value.trim()
  if (DNI_REGEX.test(trimmed)) return true
  return isValidCuit(trimmed)
}
