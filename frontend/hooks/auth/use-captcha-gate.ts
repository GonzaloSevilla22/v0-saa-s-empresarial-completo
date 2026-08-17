"use client"

import { useCallback, useEffect, useMemo, useRef, useState, type RefObject } from "react"
import type { CaptchaWidgetHandle } from "@/components/auth/CaptchaWidget"
import {
  CAPTCHA_REFRESH_TIMEOUT_MS,
  CAPTCHA_RENEWAL_FAILED_MESSAGE,
  CAPTCHA_RENEWAL_LABEL,
  captchaGateReducer,
  createInitialCaptchaGateState,
  submitWithFreshCaptcha,
  type CaptchaGateEvent,
  type CaptchaGatePhase,
  type CaptchaGateState,
} from "@/lib/captcha-freshness"

/** Props listas para esparcir sobre el `<CaptchaWidget>` de la pantalla. */
export interface CaptchaGateWidgetProps {
  onVerify: (token: string) => void
  onExpire: () => void
  onError: () => void
}

/**
 * Props listas para esparcir sobre el botón de submit. `aria-disabled` sólo
 * está presente (en `true`) durante la renovación (D2 en design.md): el
 * botón queda semánticamente deshabilitado mientras sigue siendo clickeable,
 * para poder encolar la intención del usuario. `disabled` real cubre el
 * arranque en frío y un submit ya en vuelo.
 */
export interface CaptchaGateSubmitButtonProps {
  disabled: boolean
  "aria-disabled"?: true
}

export interface UseCaptchaGateResult {
  /** Ref a pasar como `ref` del `<CaptchaWidget>`. */
  captchaRef: RefObject<CaptchaWidgetHandle | null>
  /** `onVerify`/`onExpire`/`onError` listos para esparcir sobre el widget. */
  captchaProps: CaptchaGateWidgetProps
  /** Token vigente (`""` sin token). */
  token: string
  /** Fase actual de la compuerta (D3 en design.md). */
  phase: CaptchaGatePhase
  /** `true` en `renewing` o `queued` — atajo para el rótulo/estilo apagado de cada pantalla. */
  isRenewing: boolean
  /** `true` mientras hay un submit real en vuelo (vía `submit()`). */
  isLoading: boolean
  /** `disabled`/`aria-disabled` listos para esparcir sobre el botón de submit. */
  submitButtonProps: CaptchaGateSubmitButtonProps
  /** Mensaje para la región `aria-live` compartida (`""` fuera de renovación). */
  statusMessage: string
  /**
   * Punto único de entrada para el submit de las 4 pantallas (D5). En
   * `ready` corre `run` de inmediato a través de `submitWithFreshCaptcha`
   * (guard de edad + reintento único intactos). En `renewing` encola `run`
   * (D4): se dispara una sola vez al llegar el próximo token fresco, o se
   * descarta con error surfaceado al vencer `CAPTCHA_REFRESH_TIMEOUT_MS`.
   * Un submit en vuelo o una intención ya encolada hacen que la llamada sea
   * un no-op (D4.1/D4.5): la promesa devuelta no se resuelve nunca, porque
   * no hay ninguna submission real que reportar para esa activación.
   */
  submit: <T>(run: (token: string) => Promise<T>) => Promise<T>
}

/**
 * Hook de auth que ata token + fase de renovación + cola de submit +
 * `submitWithFreshCaptcha` (D5 en design.md). Es el único punto que las 4
 * pantallas (login, registro, recuperación de contraseña, `MagicLinkForm`)
 * consumen — ninguna reimplementa el ciclo de captcha.
 */
export function useCaptchaGate(): UseCaptchaGateResult {
  const captchaRef = useRef<CaptchaWidgetHandle>(null)
  const [token, setToken] = useState("")
  const [gate, setGate] = useState<CaptchaGateState>(createInitialCaptchaGateState)

  // Última intención encolada: `fire` ejecuta el submit real con el token
  // fresco; `reject` permite abortarla (vencimiento o error del widget) sin
  // pasar por `fire`. Viven en refs — no en el reducer — porque el reducer
  // sólo modela *que* hay una intención encolada (fase `queued`), no *cuál*
  // (D3: el reducer es puro, sin closures ni promesas).
  const pendingFireRef = useRef<((freshToken: string) => void) | null>(null)
  const pendingRejectRef = useRef<((reason: unknown) => void) | null>(null)
  const queueTimerRef = useRef<ReturnType<typeof setTimeout> | null>(null)

  // Ref con el token vigente para que `submit()` lea el valor más reciente
  // sin tener que recrear su identidad en cada cambio de `token`.
  const tokenRef = useRef(token)
  tokenRef.current = token

  const dispatchGate = useCallback((event: CaptchaGateEvent) => {
    setGate((prev) => captchaGateReducer(prev, event))
  }, [])

  const clearQueueTimer = useCallback(() => {
    if (queueTimerRef.current !== null) {
      clearTimeout(queueTimerRef.current)
      queueTimerRef.current = null
    }
  }, [])

  const clearPendingQueue = useCallback(() => {
    clearQueueTimer()
    pendingFireRef.current = null
    pendingRejectRef.current = null
  }, [clearQueueTimer])

  // Desmontaje (3.9): limpiar el timer de la cola evita que un submit se
  // dispare (o que se llame a setState) después de que la pantalla se fue.
  useEffect(() => clearQueueTimer, [clearQueueTimer])

  const executeSubmission = useCallback(
    async <T,>(run: (submitToken: string) => Promise<T>, submitToken: string): Promise<T> => {
      dispatchGate({ type: "submitStarted" })
      try {
        const result = await submitWithFreshCaptcha({ captcha: captchaRef.current, token: submitToken, run })
        dispatchGate({ type: "submitSettled" })
        return result
      } catch (error) {
        // Token de un solo uso: tras un rechazo, re-challenge (D2/D4.6) —
        // mismo tratamiento que el `catch` que hoy repiten las 4 pantallas.
        captchaRef.current?.reset()
        setToken("")
        dispatchGate({ type: "submitSettled" })
        dispatchGate({ type: "tokenLost" })
        throw error
      }
    },
    [dispatchGate],
  )

  const handleVerify = useCallback(
    (newToken: string) => {
      setToken(newToken)
      dispatchGate({ type: "tokenIssued" })
      // Si había una intención encolada, éste es el token fresco que la
      // dispara — exactamente una vez (D4.2): `pendingFireRef` se limpia
      // antes de invocar `fire`, así que un segundo `onVerify` no puede
      // volver a dispararla (ya no hay nada que disparar).
      const fire = pendingFireRef.current
      if (fire) {
        clearPendingQueue()
        fire(newToken)
      }
    },
    [dispatchGate, clearPendingQueue],
  )

  const handleExpire = useCallback(() => {
    setToken("")
    // tokenLost ya modela D4.6 en el reducer: si había cola (`queued`), se
    // mantiene — una notificación más de renovación no descarta la intención.
    dispatchGate({ type: "tokenLost" })
  }, [dispatchGate])

  const handleError = useCallback(() => {
    setToken("")
    const reject = pendingRejectRef.current
    if (pendingFireRef.current) {
      // D4.4: un error del widget aborta la cola sin esperar el timeout —
      // no hay token en camino, esperar sería mentirle al usuario.
      clearPendingQueue()
      dispatchGate({ type: "queueAborted" })
      reject?.(new Error(CAPTCHA_RENEWAL_FAILED_MESSAGE))
    } else {
      dispatchGate({ type: "tokenLost" })
    }
  }, [dispatchGate, clearPendingQueue])

  const captchaProps = useMemo<CaptchaGateWidgetProps>(
    () => ({ onVerify: handleVerify, onExpire: handleExpire, onError: handleError }),
    [handleVerify, handleExpire, handleError],
  )

  const submit = useCallback(
    <T,>(run: (submitToken: string) => Promise<T>): Promise<T> => {
      // Doble red anti-doble-submit (D4.5) y "a lo sumo una intención"
      // (D4.1): con un submit en vuelo, o con una intención ya encolada,
      // esta activación no hace nada. La promesa nunca se resuelve — no hay
      // ninguna submission real detrás de esta llamada en particular.
      if (gate.isSubmitting || pendingFireRef.current) {
        return new Promise<T>(() => {})
      }

      if (gate.phase === "ready") {
        return executeSubmission(run, tokenRef.current)
      }

      if (gate.phase === "renewing") {
        return new Promise<T>((resolve, reject) => {
          pendingFireRef.current = (freshToken: string) => {
            executeSubmission(run, freshToken).then(resolve, reject)
          }
          pendingRejectRef.current = reject
          dispatchGate({ type: "submitRequested" })
          queueTimerRef.current = setTimeout(() => {
            clearPendingQueue()
            dispatchGate({ type: "queueExpired" })
            reject(new Error(CAPTCHA_RENEWAL_FAILED_MESSAGE))
          }, CAPTCHA_REFRESH_TIMEOUT_MS)
        })
      }

      // "cold": inalcanzable en la práctica (el botón tiene `disabled` real).
      return new Promise<T>(() => {})
    },
    [gate.phase, gate.isSubmitting, executeSubmission, dispatchGate, clearPendingQueue],
  )

  const isRenewing = gate.phase === "renewing" || gate.phase === "queued"

  const submitButtonProps = useMemo<CaptchaGateSubmitButtonProps>(() => {
    if (gate.isSubmitting || gate.phase === "cold") {
      return { disabled: true }
    }
    if (isRenewing) {
      return { disabled: false, "aria-disabled": true }
    }
    return { disabled: false }
  }, [gate.isSubmitting, gate.phase, isRenewing])

  return {
    captchaRef,
    captchaProps,
    token,
    phase: gate.phase,
    isRenewing,
    isLoading: gate.isSubmitting,
    submitButtonProps,
    statusMessage: isRenewing ? CAPTCHA_RENEWAL_LABEL : "",
    submit,
  }
}
