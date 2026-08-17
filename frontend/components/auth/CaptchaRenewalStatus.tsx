interface CaptchaRenewalStatusProps {
  /** Mensaje a anunciar. Vacío ("") = fuera de renovación, no se renderiza nada. */
  message: string
}

/**
 * Región `aria-live` compartida por las 4 pantallas de auth (D6 en
 * design.md). Un cambio de rótulo dentro de un botón no enfocado no se
 * anuncia solo — esta región lo hace explícito. `aria-live="polite"` (no
 * `assertive`): es información de contexto, no una alerta que deba
 * interrumpir al usuario. Fuera de renovación no se monta nada (message
 * vacío), y al cambiar entre mensajes no vacíos el mismo nodo persiste
 * (no se remonta), para que el lector de pantalla lo anuncie.
 */
export function CaptchaRenewalStatus({ message }: CaptchaRenewalStatusProps) {
  if (!message) return null
  return (
    <span role="status" aria-live="polite" className="sr-only">
      {message}
    </span>
  )
}
