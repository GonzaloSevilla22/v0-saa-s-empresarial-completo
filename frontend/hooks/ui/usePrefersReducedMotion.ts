"use client"

import { useMediaQuery } from "./use-media-query"

/**
 * Reactive, SSR-safe read of `prefers-reduced-motion: reduce`.
 *
 * SSR-safe because it's a thin wrapper over `useMediaQuery`, which returns
 * `false` until mounted (matchMedia is client-only) and subscribes to the
 * media query's `change` event so a live OS-setting toggle updates the
 * value without a reload.
 *
 * Consumed by `components/motion/*` (FadeIn, MotionList, Celebrate) to
 * degrade animations per spec `visual-design-system`, Requirement "Sistema
 * de micro-animaciones 2D con respeto de reduced-motion".
 *
 * @example
 * const prefersReducedMotion = usePrefersReducedMotion()
 * const variants = getFadeInVariants(prefersReducedMotion)
 */
export function usePrefersReducedMotion(): boolean {
  return useMediaQuery("(prefers-reduced-motion: reduce)")
}
