/**
 * tablero-explicable (D7) — capa canónica del Resumen IA del día.
 *
 * `ai-resumen` responde `{ ok, data }` donde `data` es:
 *   - la fila de `public.insights` (`to_jsonb`): el texto vive en `message`,
 *     la columna real de la tabla — leer `content` dejó la tarjeta en el
 *     fallback durante meses (PO 2026-11-06: «nunca muestra nada»);
 *   - o el texto crudo de OpenAI, cuando la RPC de log degrada.
 *
 * Acá viven la lectura de esa respuesta y los mensajes de error legibles, para
 * que el hook y la tarjeta compartan UNA definición y sean testeables sin
 * React.
 */

/** La llamada superó el tope de espera (toda la operación: token, petición y respuesta). */
export class AiSummaryTimeoutError extends Error {
  constructor() {
    super("ai-resumen: tope de espera vencido")
    this.name = "AiSummaryTimeoutError"
  }
}

/** La función respondió con éxito pero sin texto de resumen. */
export class AiSummaryEmptyError extends Error {
  constructor() {
    super("ai-resumen: respuesta sin texto")
    this.name = "AiSummaryEmptyError"
  }
}

function nonEmptyString(value: unknown): string | null {
  return typeof value === "string" && value.trim() !== "" ? value : null
}

/**
 * Texto del resumen a partir del cuerpo de `ai-resumen`, o `null` si no hay.
 * Acepta el texto crudo, la fila de insights (`message`) y, de respaldo, la
 * tabla legacy (`content`). Nunca inventa un resumen.
 */
export function parseAiSummaryResponse(body: unknown): string | null {
  const row = (body as { data?: unknown } | null | undefined)?.data
  if (typeof row === "string") return nonEmptyString(row)
  if (row && typeof row === "object") {
    const r = row as { message?: unknown; content?: unknown }
    return nonEmptyString(r.message) ?? nonEmptyString(r.content)
  }
  return null
}

/** Estado HTTP de un `FunctionsHttpError` (`context` es la `Response`). */
function httpStatusOf(err: unknown): number | null {
  const status = (err as { context?: { status?: unknown } } | null | undefined)?.context?.status
  return typeof status === "number" ? status : null
}

/** Mensaje legible para el usuario según el tipo de falla. */
export function aiSummaryErrorMessage(err: unknown): string {
  if (err instanceof AiSummaryTimeoutError) return "La IA tardó demasiado. Probá con Regenerar."
  if (err instanceof AiSummaryEmptyError) return "La IA no devolvió un resumen. Probá con Regenerar."

  const status = httpStatusOf(err)
  if (status === 429) {
    return "Llegaste al límite mensual de consultas de IA de tu plan. Se reinicia el 1.º de cada mes."
  }
  if (status === 401) return "Tu sesión venció. Volvé a ingresar."
  return "No pudimos generar el resumen. Probá con Regenerar en unos minutos."
}
