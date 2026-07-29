/**
 * Pure builders for framer-motion `Variants`/`Transition` objects, shared by
 * `FadeIn`, `MotionList`/`MotionListItem` and `Celebrate` (components/motion/*).
 *
 * Kept as plain functions (no React, no framer-motion runtime dependency
 * beyond types) so the "reads shared motion tokens" and "degrades under
 * `prefers-reduced-motion: reduce`" behavior is unit-testable without
 * mounting a component — see __tests__/lib/motion-variants.test.ts.
 *
 * Contract (design.md D4 / spec `visual-design-system`): all durations/eases
 * come from `lib/motion-tokens.ts` (the JS mirror of the CSS motion tokens in
 * `app/globals.css`). Reduced motion never *visually* moves/scales content —
 * matching the spec scenario "Respeto de prefers-reduced-motion".
 *
 * GOTCHA (found via component-level integration tests, not these pure-function
 * tests): `usePrefersReducedMotion` is SSR-safe, so it always resolves `false`
 * on the very first client render and corrects asynchronously after mount
 * (see `hooks/ui/usePrefersReducedMotion.ts`). That means the *first* frame
 * a `components/motion/*` wrapper ever renders always uses the full-motion
 * `hidden` variant (e.g. `y: 12`) — even for a user with reduced-motion
 * enabled — because the hook hasn't corrected yet. Framer Motion applies
 * that `hidden` snapshot as a real motion value. If the reduced-motion
 * variant then merely *omits* `y`/`scale` (rather than explicitly zeroing
 * it), Framer Motion has no target to animate that value back to, so the
 * residual offset/scale from the transient full-motion frame stays frozen
 * forever — the element ends up permanently mispositioned. Fix: reduced
 * variants below explicitly set the neutral value (`y: 0` / `scale: 1`)
 * instead of leaving the key out, so any residual from the transient frame
 * is always overwritten once the hook resolves.
 */

import type { Transition, Variants } from "framer-motion"
import {
  MOTION_DURATION,
  MOTION_EASE,
  REDUCED_MOTION_TRANSITION,
} from "@/lib/motion-tokens"

/** Entrada estándar (fade + slide sutil) usada por `FadeIn`. */
export function getFadeInVariants(prefersReducedMotion: boolean): Variants {
  if (prefersReducedMotion) {
    // `y: 0` explícito (no omitido) — ver GOTCHA arriba.
    return { hidden: { opacity: 0, y: 0 }, visible: { opacity: 1, y: 0 } }
  }
  return {
    hidden: { opacity: 0, y: 12 },
    visible: { opacity: 1, y: 0 },
  }
}

/** Transición de `FadeIn`. `delay` se ignora bajo reduced-motion. */
export function getFadeInTransition(
  prefersReducedMotion: boolean,
  delay = 0,
): Transition {
  if (prefersReducedMotion) return { ...REDUCED_MOTION_TRANSITION }
  return {
    duration: MOTION_DURATION.base,
    ease: MOTION_EASE.standard as unknown as Transition["ease"],
    delay,
  }
}

/** Variants del contenedor de `MotionList` — controla el stagger de hijos. */
export function getMotionListContainerVariants(
  prefersReducedMotion: boolean,
  staggerDelay = 0.06,
): Variants {
  return {
    hidden: {},
    visible: {
      transition: prefersReducedMotion
        ? { staggerChildren: 0 }
        : { staggerChildren: staggerDelay, delayChildren: 0.02 },
    },
  }
}

/** Variants de cada `MotionListItem` dentro de un `MotionList`. */
export function getMotionListItemVariants(
  prefersReducedMotion: boolean,
): Variants {
  if (prefersReducedMotion) {
    // `y: 0` explícito (no omitido) — ver GOTCHA arriba.
    return {
      hidden: { opacity: 0, y: 0 },
      visible: {
        opacity: 1,
        y: 0,
        transition: { ...REDUCED_MOTION_TRANSITION },
      },
    }
  }
  return {
    hidden: { opacity: 0, y: 16 },
    visible: {
      opacity: 1,
      y: 0,
      transition: {
        duration: MOTION_DURATION.base,
        ease: MOTION_EASE.standard as unknown as Transition["ease"],
      },
    },
  }
}

/** Variants de `Celebrate` — pop de escala para feedback de éxito/hito. */
export function getCelebrateVariants(prefersReducedMotion: boolean): Variants {
  if (prefersReducedMotion) {
    // `scale: 1` explícito (no omitido) — ver GOTCHA arriba.
    return {
      hidden: { opacity: 0, scale: 1 },
      visible: {
        opacity: 1,
        scale: 1,
        transition: { ...REDUCED_MOTION_TRANSITION },
      },
    }
  }
  return {
    hidden: { opacity: 0, scale: 0.85 },
    visible: {
      opacity: 1,
      scale: 1,
      transition: {
        duration: MOTION_DURATION.slow,
        ease: MOTION_EASE.emphasized as unknown as Transition["ease"],
      },
    },
  }
}
