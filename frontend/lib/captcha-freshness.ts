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

/**
 * Rótulo compartido por las 4 pantallas de auth mientras el captcha se está
 * renovando (change captcha-renewal-feedback, D2/D5 en design.md). Cada
 * pantalla conserva su propio rótulo normal ("Iniciar sesión", "Crear
 * cuenta", ...) y sólo lo intercambia por éste cuando `isRenewing`.
 */
export const CAPTCHA_RENEWAL_LABEL = "Renovando verificación…"

/**
 * Mensaje surfaceado cuando la cola de submit se descarta sin haber podido
 * renovar el captcha: por vencimiento del timeout compartido (D4.3) o porque
 * el widget reportó un error mientras había una intención encolada (D4.4).
 * Un solo mensaje para ambos casos: para el usuario la situación es la
 * misma ("no se pudo renovar, probá de nuevo").
 */
export const CAPTCHA_RENEWAL_FAILED_MESSAGE = "No pudimos renovar la verificación. Probá de nuevo."

/**
 * Fase de la compuerta de captcha (D3 en design.md):
 *
 * - `cold`: nunca hubo token emitido. Arranque en frío, NO es una renovación
 *   — el botón conserva el `disabled` real de siempre.
 * - `ready`: hay un token vigente. Comportamiento normal de submit.
 * - `renewing`: hubo un token y se perdió (auto-renovación por visibilidad,
 *   expiración propia de Turnstile, error del widget, o el `reset()` de un
 *   submit rechazado). Un challenge nuevo ya está en camino.
 * - `queued`: `renewing` + el usuario activó el submit. Al llegar el
 *   próximo token fresco, esa intención se dispara — una sola vez.
 */
export type CaptchaGatePhase = "cold" | "ready" | "renewing" | "queued"

/** Estado completo de la compuerta: fase + si hay un submit en vuelo. */
export interface CaptchaGateState {
  readonly phase: CaptchaGatePhase
  readonly isSubmitting: boolean
}

/** Fábrica del estado inicial — cada consumidor arranca en `cold`. */
export function createInitialCaptchaGateState(): CaptchaGateState {
  return { phase: "cold", isSubmitting: false }
}

/**
 * Eventos que maneja `captchaGateReducer`. Los dispara el hook que envuelve
 * la compuerta (`use-captcha-gate.ts`) a partir de los callbacks del widget
 * (`onVerify`/`onExpire`/`onError`), del click de submit, del vencimiento del
 * timer de la cola, y del ciclo de vida de un submit real.
 */
export type CaptchaGateEvent =
  /** El widget emitió un token (challenge resuelto). */
  | { type: "tokenIssued" }
  /** El token vigente se invalidó (expiración, error del widget, o auto-renovación por visibilidad). */
  | { type: "tokenLost" }
  /** El usuario activó el submit. Sólo encola si la fase es `renewing`. */
  | { type: "submitRequested" }
  /** La cola venció sin que llegara un token fresco (`CAPTCHA_REFRESH_TIMEOUT_MS`). */
  | { type: "queueExpired" }
  /** El widget reportó un error mientras había una intención encolada. */
  | { type: "queueAborted" }
  /** Arrancó una ejecución real de `submitWithFreshCaptcha`. */
  | { type: "submitStarted" }
  /** Terminó (con éxito o error) la ejecución de `submitWithFreshCaptcha`. */
  | { type: "submitSettled" }

/**
 * Reducer puro de la compuerta de captcha (D3 en design.md). Sin React, sin
 * timers ni promesas: sólo transiciones de fase y del flag `isSubmitting`.
 *
 * La cola ("a lo sumo una intención") no vive acá — el reducer sólo modela
 * *que* hay una intención encolada (fase `queued`), no *cuál*; el callback a
 * ejecutar lo retiene el hook en un `ref`. La transición `queued -> ready`
 * sobre un evento `tokenIssued` ES la señal de "disparar el submit
 * encolado": el consumidor la reconoce comparando la fase previa a la
 * dispatch, así que sólo puede dispararse una vez por intención encolada
 * (D4.2) — un segundo `tokenIssued` ya parte de `ready`, no de `queued`.
 */
export function captchaGateReducer(state: CaptchaGateState, event: CaptchaGateEvent): CaptchaGateState {
  switch (event.type) {
    case "tokenIssued":
      return { ...state, phase: "ready" }

    case "tokenLost":
      // Arranque en frío no es renovación (D1); y una intención ya
      // encolada sobrevive a una notificación adicional de pérdida de
      // token — sigue siendo "el mismo challenge en camino" (D4.6).
      if (state.phase === "cold" || state.phase === "queued") return state
      return { ...state, phase: "renewing" }

    case "submitRequested":
      // Doble red anti-doble-submit (D4.5): con un submit en vuelo, no-op
      // sin importar la fase.
      if (state.isSubmitting) return state
      // Sólo `renewing` encola. `ready` no necesita cola (el submit corre
      // directo); `cold`/`queued` no tienen nada nuevo que hacer.
      if (state.phase === "renewing") return { ...state, phase: "queued" }
      return state

    case "queueExpired":
    case "queueAborted":
      if (state.phase !== "queued") return state
      return { ...state, phase: "renewing" }

    case "submitStarted":
      // Inalcanzable por construcción en uso normal (el hook sólo dispara
      // esto tras una transición a `ready`), pero el reducer lo garantiza
      // también a nivel de tipos/transiciones: nunca se entra en
      // "submitting" estando `queued`.
      if (state.phase === "queued") return state
      return { ...state, isSubmitting: true }

    case "submitSettled":
      return { ...state, isSubmitting: false }

    default: {
      const exhaustiveCheck: never = event
      return exhaustiveCheck
    }
  }
}
