/**
 * Política de frescura de token de captcha — capa canónica compartida por las
 * 4 superficies que usan `CaptchaWidget` (login, registro, recuperación de
 * contraseña y `MagicLinkForm`). Se resuelve una sola vez acá; ninguna
 * pantalla reimplementa el ciclo (change captcha-token-freshness).
 */

/**
 * Antigüedad máxima aceptada para un token de Turnstile antes de considerarlo
 * viejo. La vida útil real de Cloudflare es de ~300s; se usa un umbral de 2
 * minutos (margen ~2,5×) para cubrir el tiempo entre la renovación y el
 * submit real del usuario, sin resetear en cada alt-tab corto.
 */
export const CAPTCHA_MAX_TOKEN_AGE_MS = 120_000

/**
 * Tiempo máximo que se espera a que `CaptchaWidget.refresh()` entregue un
 * token nuevo antes de rendirse. Valor conservador (OQ-4 en design.md): si en
 * producción se observan timeouts espurios, se ajusta acá.
 */
export const CAPTCHA_REFRESH_TIMEOUT_MS = 10_000

/**
 * Predicado puro: ¿el token emitido en `mintedAt` superó `maxAgeMs` respecto
 * de `now`? `now` se recibe explícito para que los tests inyecten instantes
 * sin depender de timers ni de `Date.now()`.
 *
 * Sin token emitido (`mintedAt === null`) nunca es viejo: no hay nada que
 * renovar. En el borde (edad === maxAgeMs) todavía se considera fresco — sólo
 * pasa a viejo cuando la edad *supera* el umbral, no cuando lo iguala.
 */
export function isTokenStale(
  mintedAt: number | null,
  now: number,
  maxAgeMs: number = CAPTCHA_MAX_TOKEN_AGE_MS,
): boolean {
  if (mintedAt === null) return false
  return now - mintedAt > maxAgeMs
}

const CAPTCHA_ERROR_PATTERNS = [/captcha protection/i, /timeout-or-duplicate/i, /invalid-input-response/i]

function extractErrorMessage(error: unknown): string | null {
  if (error instanceof Error) return error.message
  if (typeof error === "string") return error
  if (
    typeof error === "object" &&
    error !== null &&
    "message" in error &&
    typeof (error as { message: unknown }).message === "string"
  ) {
    return (error as { message: string }).message
  }
  return null
}

/**
 * Reconoce si `error` es un rechazo de captcha de Supabase/Cloudflare
 * (`captcha protection`, `timeout-or-duplicate`, `invalid-input-response`),
 * sin asumir su forma: soporta `Error`, `string` y objetos con `.message`.
 * Estrecha `unknown` sin usar `any`. Cualquier otro error (credenciales,
 * red, rate limit) devuelve `false`.
 */
export function isCaptchaError(error: unknown): boolean {
  const message = extractErrorMessage(error)
  if (!message) return false
  return CAPTCHA_ERROR_PATTERNS.some((pattern) => pattern.test(message))
}

/** Error tipado que rechaza `CaptchaWidgetHandle.refresh()` al agotar el timeout. */
export class CaptchaRefreshTimeoutError extends Error {
  constructor(timeoutMs: number) {
    super(`Captcha refresh timed out after ${timeoutMs}ms`)
    this.name = "CaptchaRefreshTimeoutError"
  }
}

/** Subconjunto de `CaptchaWidgetHandle` que necesita la política de envío. */
export interface CaptchaFreshnessHandle {
  isStale: (maxAgeMs?: number) => boolean
  refresh: (timeoutMs?: number) => Promise<string>
}

interface SubmitWithFreshCaptchaOptions<T> {
  /** Handle del widget (vía ref). `null`/`undefined` degrada a no reintentar. */
  captcha: CaptchaFreshnessHandle | null | undefined
  /** Token actual en el estado del formulario. */
  token: string
  /** Acción que llama a Supabase con el token vigente. */
  run: (token: string) => Promise<T>
}

/**
 * Política completa de envío con captcha fresco (D4 en design.md):
 *
 * 1. Si el token está viejo, se renueva antes de llamar a `run`.
 * 2. Se ejecuta `run(token)`.
 * 3. Si falla por un error de captcha, se renueva el token y se reintenta
 *    `run` **una sola vez**.
 * 4. Cualquier otro error, o el fallo del reintento (incluido el timeout de
 *    `refresh`), se propaga tal cual al `catch` del consumidor.
 *
 * El contador de reintentos es local a la llamada: no hay estado compartido
 * entre submits, así que no hay forma de encadenar dos reintentos.
 */
export async function submitWithFreshCaptcha<T>({
  captcha,
  token,
  run,
}: SubmitWithFreshCaptchaOptions<T>): Promise<T> {
  const freshToken = captcha?.isStale() ? await captcha.refresh() : token

  try {
    return await run(freshToken)
  } catch (error) {
    if (!captcha || !isCaptchaError(error)) {
      throw error
    }
    const retryToken = await captcha.refresh()
    return await run(retryToken)
  }
}
