/**
 * Constantes JS de los tokens de motion — espejo de las CSS vars declaradas
 * en `app/globals.css` (`--motion-duration-*` / `--motion-ease-*`).
 *
 * Por qué duplicado: Framer Motion evalúa `transition.duration`/`transition.ease`
 * en JS (necesita number/array), no puede leer `var(--motion-duration-base)`
 * desde su prop `transition`. Este archivo es la fuente que consumen
 * `components/motion/*`; las utilities Tailwind (`duration-base`, `ease-standard`)
 * son la fuente para transiciones puramente CSS.
 *
 * Si se cambia un valor acá, actualizar también `app/globals.css` en el mismo
 * commit (y viceversa) — ver `frontend/docs/design-tokens.md`.
 */

/** Duraciones en segundos (unidad que espera Framer Motion). */
export const MOTION_DURATION = {
  /** 120ms — micro-feedback: hover, press, toggle. */
  fast: 0.12,
  /** 200ms — transición estándar: entrada de card, fade. */
  base: 0.2,
  /** 320ms — transición enfatizada: modales, listas con stagger. */
  slow: 0.32,
} as const

/** Curvas de easing como arrays cubic-bezier (formato que espera Framer Motion). */
export const MOTION_EASE = {
  /** cubic-bezier(0.4, 0, 0.2, 1) — curva estándar Material. */
  standard: [0.4, 0, 0.2, 1],
  /** cubic-bezier(0.2, 0, 0, 1) — decelerate enfatizado, sensación de "llegada". */
  emphasized: [0.2, 0, 0, 1],
} as const

/** Transición "mínima" a la que degradan las animaciones con reduced-motion. */
export const REDUCED_MOTION_TRANSITION = {
  duration: MOTION_DURATION.fast,
  ease: 'linear',
} as const
