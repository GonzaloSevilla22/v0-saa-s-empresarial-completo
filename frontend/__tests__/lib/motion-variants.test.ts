/**
 * Tests for the pure motion-variant builders that back components/motion/*
 * (FadeIn, MotionList, Celebrate). Extracted as pure functions specifically
 * so the "reads shared motion tokens" and "degrades under reduced-motion"
 * behavior (spec `visual-design-system`, Requirement "Sistema de
 * micro-animaciones 2D...") is testable without mounting React/framer-motion.
 *
 * Cycle: RED (this file, before components/motion/variants.ts exists) →
 * GREEN → TRIANGULATE (>=2 cases per behavior: standard motion vs
 * reduced-motion) → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import {
  getFadeInVariants,
  getFadeInTransition,
  getMotionListContainerVariants,
  getMotionListItemVariants,
  getCelebrateVariants,
} from "@/components/motion/variants"
import { MOTION_DURATION, MOTION_EASE } from "@/lib/motion-tokens"

describe("getFadeInVariants", () => {
  // ── RED/GREEN: happy path — full motion ──
  it("includes a y offset in the hidden state when reduced motion is not requested", () => {
    const variants = getFadeInVariants(false)
    expect(variants.hidden).toMatchObject({ opacity: 0, y: 12 })
    expect(variants.visible).toMatchObject({ opacity: 1, y: 0 })
  })

  // ── TRIANGULATE: edge case — reduced motion ──
  // `y: 0` explícito (no omitido): usePrefersReducedMotion es SSR-safe y
  // resuelve `false` en el primer frame, así que el primer montaje siempre
  // aplica el `hidden` de full-motion (y: 12) antes de corregirse. Si el
  // variant reducido omitiera `y`, Framer Motion no tendría a qué animarlo
  // de vuelta y el offset quedaría congelado — ver GOTCHA en variants.ts.
  it("neutralizes the y offset (y: 0, no desplazamiento) when reduced motion is requested", () => {
    const variants = getFadeInVariants(true)
    expect(variants.hidden).toEqual({ opacity: 0, y: 0 })
    expect(variants.visible).toEqual({ opacity: 1, y: 0 })
  })
})

describe("getFadeInTransition", () => {
  it("uses the shared base duration and standard easing token by default", () => {
    const transition = getFadeInTransition(false)
    expect(transition.duration).toBe(MOTION_DURATION.base)
    expect(transition.ease).toEqual(MOTION_EASE.standard)
  })

  it("forwards a delay when provided and not reduced", () => {
    const transition = getFadeInTransition(false, 0.15)
    expect(transition.delay).toBe(0.15)
  })

  it("degrades to the fast/linear reduced-motion transition and ignores delay", () => {
    const transition = getFadeInTransition(true, 0.5)
    expect(transition.duration).toBe(MOTION_DURATION.fast)
    expect(transition.ease).toBe("linear")
    expect(transition.delay).toBeUndefined()
  })
})

describe("getMotionListContainerVariants", () => {
  it("staggers children with the requested delay when motion is enabled", () => {
    const variants = getMotionListContainerVariants(false, 0.08)
    const visible = variants.visible as { transition?: { staggerChildren?: number } }
    expect(visible.transition?.staggerChildren).toBe(0.08)
  })

  it("collapses staggerChildren to 0 under reduced motion", () => {
    const variants = getMotionListContainerVariants(true, 0.08)
    const visible = variants.visible as { transition?: { staggerChildren?: number } }
    expect(visible.transition?.staggerChildren).toBe(0)
  })
})

describe("getMotionListItemVariants", () => {
  it("animates items with a y offset and base duration by default", () => {
    const variants = getMotionListItemVariants(false)
    expect(variants.hidden).toMatchObject({ opacity: 0, y: 16 })
    const visible = variants.visible as { transition?: { duration?: number } }
    expect(visible.transition?.duration).toBe(MOTION_DURATION.base)
  })

  // `y: 0` explícito (no omitido) — mismo motivo que en getFadeInVariants.
  it("neutralizes the y offset (y: 0) under reduced motion instead of omitting it", () => {
    const variants = getMotionListItemVariants(true)
    expect((variants.hidden as Record<string, unknown>).y).toBe(0)
    const visible = variants.visible as Record<string, unknown>
    expect(visible.y).toBe(0)
  })
})

describe("getCelebrateVariants", () => {
  it("scales in with the slow duration and emphasized easing by default", () => {
    const variants = getCelebrateVariants(false)
    expect(variants.hidden).toMatchObject({ opacity: 0, scale: 0.85 })
    const visible = variants.visible as { transition?: { duration?: number; ease?: unknown } }
    expect(visible.transition?.duration).toBe(MOTION_DURATION.slow)
    expect(visible.transition?.ease).toEqual(MOTION_EASE.emphasized)
  })

  // `scale: 1` explícito (no omitido) — mismo motivo que en getFadeInVariants.
  it("neutralizes the scale transform (scale: 1) under reduced motion instead of omitting it", () => {
    const variants = getCelebrateVariants(true)
    expect((variants.hidden as Record<string, unknown>).scale).toBe(1)
    const visible = variants.visible as Record<string, unknown>
    expect(visible.scale).toBe(1)
  })
})
