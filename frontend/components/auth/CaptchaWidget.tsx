"use client"

import { forwardRef, useCallback, useEffect, useImperativeHandle, useRef, useState } from "react"
import { Turnstile, type TurnstileInstance, type TurnstileTheme } from "@marsidev/react-turnstile"
import {
  CAPTCHA_REFRESH_TIMEOUT_MS,
  CaptchaRefreshTimeoutError,
  isTokenStale,
} from "@/lib/captcha-freshness"

const PLAYWRIGHT_STUB_TOKEN = "playwright-local-captcha-stub"

export interface CaptchaWidgetHandle {
  /** Re-lanza el challenge (tras un error/expiración o un signUp/login rechazado). También limpia `mintedAt`. */
  reset: () => void
  /**
   * `true` sólo si hay un token emitido y su edad supera `maxAgeMs` (default
   * `CAPTCHA_MAX_TOKEN_AGE_MS`). Sin token emitido → `false`: el botón ya
   * está deshabilitado por falta de token, no hay nada viejo que renovar.
   * En el stub local de Playwright siempre es `false` (D5): el token del
   * stub no caduca.
   */
  isStale: (maxAgeMs?: number) => boolean
  /**
   * Resetea el challenge y resuelve con el **próximo** token emitido.
   * Rechaza con `CaptchaRefreshTimeoutError` si no llega dentro de
   * `timeoutMs` (default `CAPTCHA_REFRESH_TIMEOUT_MS`). En el stub local de
   * Playwright resuelve de inmediato con el token del stub (D5): un reset
   * ahí nunca produciría un token de reemplazo real.
   */
  refresh: (timeoutMs?: number) => Promise<string>
}

interface CaptchaWidgetProps {
  /** Se llama con el token cuando el challenge se resuelve con éxito. */
  onVerify: (token: string) => void
  /**
   * Se llama cuando el token deja de servir: expiración propia de Turnstile,
   * error del widget, **o** cuando el widget lo invalida por rancio al
   * volver la pestaña a visible (auto-renovación por visibilidad, D3). En
   * los tres casos el efecto que espera el consumidor es el mismo — limpiar
   * el token en el form —, por eso se reutiliza esta prop en vez de agregar
   * una quinta sólo para el caso de frescura.
   */
  onExpire?: () => void
  /** Se llama ante un error del widget (limpiar el token en el form). */
  onError?: () => void
  theme?: TurnstileTheme
  className?: string
}

/**
 * Wrapper de Cloudflare Turnstile para las pantallas de auth.
 *
 * - Lee la *site key* pública de `NEXT_PUBLIC_TURNSTILE_SITE_KEY`.
 * - Renderiza en español (`language: "es"`) y respeta el tema.
 * - Expone `reset()`, `isStale()` y `refresh()` vía ref (ver `CaptchaWidgetHandle`).
 * - Registra el instante de emisión del token (`mintedAt`, en un `ref`: la edad
 *   no se pinta, así que no amerita un re-render por token) y se auto-renueva
 *   cuando la pestaña vuelve a estar visible con un token viejo (change
 *   captcha-token-freshness — cierra el gap de idle-logout con pestaña en
 *   segundo plano).
 * - Degrada con un mensaje claro si falta la env var (no rompe el render).
 *
 * El token se valida server-side por Supabase Auth (`options.captchaToken`);
 * no hay validación propia en el backend.
 */
export const CaptchaWidget = forwardRef<CaptchaWidgetHandle, CaptchaWidgetProps>(
  function CaptchaWidget({ onVerify, onExpire, onError, theme = "auto", className }, ref) {
    const innerRef = useRef<TurnstileInstance | undefined>(undefined)
    const mintedAtRef = useRef<number | null>(null)
    const pendingRefreshResolversRef = useRef<Array<(token: string) => void>>([])
    const [isLocalPlaywright, setIsLocalPlaywright] = useState(false)
    const siteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY

    // Última onExpire vigente, leída desde el listener de visibilidad sin
    // que su identidad (nueva arrow function en cada render de las 4
    // pantallas) fuerce reinscribir el listener del DOM en cada render.
    const onExpireRef = useRef(onExpire)
    onExpireRef.current = onExpire

    // Detección del stub local de Playwright + registro del listener de
    // visibilidad en el MISMO efecto: `shouldUseLocalStub` se calcula acá de
    // forma síncrona y gatea ambos in situ. Separarlos en dos efectos
    // dejaría una ventana (hasta que el estado `isLocalPlaywright` se
    // propague) en la que el listener se registraría igual — exactamente lo
    // que D5 prohíbe en modo stub.
    useEffect(() => {
      const isLocalHost = window.location.hostname === "localhost" || window.location.hostname === "127.0.0.1"
      const shouldUseLocalStub =
        process.env.NODE_ENV !== "production" &&
        process.env.NEXT_PUBLIC_PLAYWRIGHT_LOCAL === "true" &&
        isLocalHost

      if (shouldUseLocalStub) {
        setIsLocalPlaywright(true)
        onVerify(PLAYWRIGHT_STUB_TOKEN)
        return
      }

      // Auto-renovación por visibilidad (D3): al volver la pestaña a visible
      // con un token rancio, se re-lanza el challenge y se notifica al
      // consumidor (vía onExpire) para que limpie el token viejo — sin
      // acción del usuario.
      function handleVisibilityChange() {
        if (document.visibilityState !== "visible") return
        if (!isTokenStale(mintedAtRef.current, Date.now())) return
        innerRef.current?.reset()
        mintedAtRef.current = null
        onExpireRef.current?.()
      }

      document.addEventListener("visibilitychange", handleVisibilityChange)
      return () => document.removeEventListener("visibilitychange", handleVisibilityChange)
    }, [onVerify])

    const handleVerify = useCallback(
      (token: string) => {
        mintedAtRef.current = Date.now()
        const resolvers = pendingRefreshResolversRef.current
        pendingRefreshResolversRef.current = []
        resolvers.forEach((settle) => settle(token))
        onVerify(token)
      },
      [onVerify],
    )

    const handleExpire = useCallback(() => {
      mintedAtRef.current = null
      onExpire?.()
    }, [onExpire])

    const handleError = useCallback(() => {
      mintedAtRef.current = null
      onError?.()
    }, [onError])

    const reset = useCallback(() => {
      innerRef.current?.reset()
      mintedAtRef.current = null
    }, [])

    const isStale = useCallback(
      (maxAgeMs?: number) => {
        if (isLocalPlaywright) return false
        return isTokenStale(mintedAtRef.current, Date.now(), maxAgeMs)
      },
      [isLocalPlaywright],
    )

    const refresh = useCallback(
      (timeoutMs: number = CAPTCHA_REFRESH_TIMEOUT_MS): Promise<string> => {
        if (isLocalPlaywright) {
          return Promise.resolve(PLAYWRIGHT_STUB_TOKEN)
        }
        return new Promise<string>((resolve, reject) => {
          const settle = (token: string) => {
            clearTimeout(timeoutId)
            resolve(token)
          }
          const timeoutId = setTimeout(() => {
            pendingRefreshResolversRef.current = pendingRefreshResolversRef.current.filter(
              (entry) => entry !== settle,
            )
            reject(new CaptchaRefreshTimeoutError(timeoutMs))
          }, timeoutMs)
          pendingRefreshResolversRef.current.push(settle)
          mintedAtRef.current = null
          innerRef.current?.reset()
        })
      },
      [isLocalPlaywright],
    )

    useImperativeHandle(ref, () => ({ reset, isStale, refresh }), [reset, isStale, refresh])

    if (isLocalPlaywright) {
      return <span data-testid="captcha-local-stub" className="sr-only">Captcha local de Playwright</span>
    }

    if (!siteKey) {
      return (
        <p role="note" className="text-xs text-amber-600 dark:text-amber-400">
          Verificación anti-bots no configurada. Definí{" "}
          <code>NEXT_PUBLIC_TURNSTILE_SITE_KEY</code> para habilitar este formulario.
        </p>
      )
    }

    return (
      <div className={className}>
        <Turnstile
          ref={innerRef}
          siteKey={siteKey}
          onSuccess={handleVerify}
          onExpire={handleExpire}
          onError={handleError}
          options={{ language: "es", theme, size: "flexible" }}
        />
      </div>
    )
  },
)
