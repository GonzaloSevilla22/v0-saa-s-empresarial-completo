/**
 * Versionado del consentimiento legal (change register-name-terms-captcha).
 *
 * `TERMS_VERSION` es el identificador que se guarda en `profiles.terms_version`
 * cuando el usuario acepta los Términos en el alta. Debe coincidir con la versión
 * mostrada en las páginas públicas `/legal/terminos` y `/legal/privacidad`.
 *
 * Al actualizar el texto legal, subí la versión (p. ej. "2026-09-v2"): los
 * consentimientos previos quedan preservados con su versión original (auditables).
 */
export const TERMS_VERSION = "2026-06-v1"

/** Fecha efectiva de la versión vigente de los documentos legales (es-AR). */
export const TERMS_EFFECTIVE_DATE = "26 de junio de 2026"

/** Rutas públicas de los documentos legales (linkeadas desde el registro). */
export const LEGAL_ROUTES = {
  terms: "/legal/terminos",
  privacy: "/legal/privacidad",
} as const
