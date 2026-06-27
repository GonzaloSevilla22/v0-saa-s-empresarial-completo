"use client"

import { forwardRef, useImperativeHandle, useRef } from "react"
import { Turnstile, type TurnstileInstance, type TurnstileTheme } from "@marsidev/react-turnstile"

export interface CaptchaWidgetHandle {
  /** Re-lanza el challenge (tras un error/expiración o un signUp/login rechazado). */
  reset: () => void
}

interface CaptchaWidgetProps {
  /** Se llama con el token cuando el challenge se resuelve con éxito. */
  onVerify: (token: string) => void
  /** Se llama cuando el token expira (limpiar el token en el form). */
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
 * - Expone `reset()` vía ref para re-challenge tras un fallo de Supabase.
 * - Degrada con un mensaje claro si falta la env var (no rompe el render).
 *
 * El token se valida server-side por Supabase Auth (`options.captchaToken`);
 * no hay validación propia en el backend.
 */
export const CaptchaWidget = forwardRef<CaptchaWidgetHandle, CaptchaWidgetProps>(
  function CaptchaWidget({ onVerify, onExpire, onError, theme = "auto", className }, ref) {
    const innerRef = useRef<TurnstileInstance | undefined>(undefined)
    const siteKey = process.env.NEXT_PUBLIC_TURNSTILE_SITE_KEY

    useImperativeHandle(ref, () => ({
      reset: () => innerRef.current?.reset(),
    }), [])

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
          onSuccess={onVerify}
          onExpire={() => onExpire?.()}
          onError={() => onError?.()}
          options={{ language: "es", theme, size: "flexible" }}
        />
      </div>
    )
  },
)
