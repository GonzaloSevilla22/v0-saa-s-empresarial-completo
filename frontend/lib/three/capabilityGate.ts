/**
 * Capability gate for immersive 3D surfaces (design.md D5 / spec
 * `immersive-3d-surfaces`, Requirement "Gate de capacidad con fallback
 * estático"). Before any `<Canvas>` mounts, the app SHALL evaluate this gate
 * and serve a static poster when the device/user doesn't qualify.
 *
 * Split in two halves on purpose:
 *  - `evaluateCapabilityGate` is a PURE function over an explicit
 *    `CapabilitySignals` snapshot — no `window`/`navigator` reads inside —
 *    so every fallback condition (and the "qualifies" case) is unit-testable
 *    without mocking the DOM/BOM. See __tests__/lib/three/capabilityGate.test.ts.
 *  - `readCapabilitySignals` is the actual browser-reading half, consumed by
 *    `hooks/three/useCapabilityGate.ts`. It is intentionally thin and
 *    untested in isolation (it's glue, not logic) — the hook's behavior is
 *    covered at the integration level instead.
 *
 * Priority order when several conditions fail at once (D5 enumeration):
 * reduced-motion → mobile/low-end → sin WebGL → save-data. This only affects
 * which `reason` is reported (useful for QA/debugging); `qualifies` is
 * `false` regardless of order once any condition fails.
 */

/** Viewport width (px) at/under which a touch device counts as "mobile" for the gate. Matches `hooks/ui/use-media-query.ts` `useIsMobile` breakpoint (max-width: 767px). */
export const MOBILE_VIEWPORT_MAX_WIDTH_PX = 767

/** `navigator.hardwareConcurrency` (logical cores) at/under which a device counts as low-end. */
export const LOW_END_HARDWARE_CONCURRENCY_MAX = 4

/** `navigator.deviceMemory` (GB, Chrome-only) at/under which a device counts as low-end. */
export const LOW_END_DEVICE_MEMORY_MAX_GB = 4

/** `navigator.connection.effectiveType` values treated as "slow connection". */
const SLOW_EFFECTIVE_TYPES = new Set(["slow-2g", "2g"])

export interface CapabilitySignals {
  /** `matchMedia('(prefers-reduced-motion: reduce)').matches` */
  prefersReducedMotion: boolean
  /** Whether the browser can create a `webgl2` or `webgl` canvas context. */
  hasWebGL: boolean
  /** `navigator.hardwareConcurrency` — `undefined` when unsupported. */
  hardwareConcurrency: number | undefined
  /** `navigator.deviceMemory` (GB) — `undefined` when unsupported (e.g. Safari, Firefox). */
  deviceMemory: number | undefined
  /** `matchMedia('(pointer: coarse)').matches` */
  pointerCoarse: boolean
  /** `window.innerWidth` */
  viewportWidth: number
  /** `navigator.connection?.saveData === true` */
  saveData: boolean
  /** `navigator.connection?.effectiveType` is `'2g'` or `'slow-2g'` */
  slowEffectiveType: boolean
}

export type CapabilityGateReason =
  | "reduced-motion"
  | "mobile-or-low-end"
  | "no-webgl"
  | "save-data"
  | "qualifies"

export interface CapabilityGateResult {
  /** `true` only when none of the fallback conditions apply. */
  qualifies: boolean
  /** Which condition decided the result — `"qualifies"` when `qualifies` is `true`. */
  reason: CapabilityGateReason
}

/**
 * "Mobile o gama baja" heuristic (D5 point 2): a device counts as mobile only
 * when BOTH a small viewport AND a coarse pointer are present together — that
 * pairing is a genuine phone signature and avoids false positives from a
 * merely-narrow desktop browser window (no coarse pointer) or a large tablet
 * in landscape (wide viewport). Low-end hardware is a separate, independent
 * signal (hardwareConcurrency/deviceMemory) that applies regardless of form
 * factor. A signal that the browser doesn't expose (`undefined`) never
 * disqualifies on its own — see the module docstring on "conservative
 * fallback".
 */
function isMobileOrLowEnd(signals: CapabilitySignals): boolean {
  const isMobileViewport =
    signals.viewportWidth <= MOBILE_VIEWPORT_MAX_WIDTH_PX && signals.pointerCoarse
  const isLowCoreCount =
    signals.hardwareConcurrency !== undefined &&
    signals.hardwareConcurrency <= LOW_END_HARDWARE_CONCURRENCY_MAX
  const isLowMemory =
    signals.deviceMemory !== undefined && signals.deviceMemory <= LOW_END_DEVICE_MEMORY_MAX_GB

  return isMobileViewport || isLowCoreCount || isLowMemory
}

/** Pure evaluation — see module docstring. */
export function evaluateCapabilityGate(signals: CapabilitySignals): CapabilityGateResult {
  if (signals.prefersReducedMotion) return { qualifies: false, reason: "reduced-motion" }
  if (isMobileOrLowEnd(signals)) return { qualifies: false, reason: "mobile-or-low-end" }
  if (!signals.hasWebGL) return { qualifies: false, reason: "no-webgl" }
  if (signals.saveData || signals.slowEffectiveType) return { qualifies: false, reason: "save-data" }
  return { qualifies: true, reason: "qualifies" }
}

/** Minimal shape of the (non-standard, Chromium-only) Network Information API. */
interface NetworkInformationLike {
  saveData?: boolean
  effectiveType?: string
}

/** `Navigator` extended with the non-standard hints this gate reads. */
interface NavigatorWithHints extends Navigator {
  deviceMemory?: number
  connection?: NetworkInformationLike
}

/** Server-safe default: never qualifies (SSR never renders 3D anyway — D2 mandates `ssr:false`). */
const SSR_SIGNALS: CapabilitySignals = {
  prefersReducedMotion: true,
  hasWebGL: false,
  hardwareConcurrency: undefined,
  deviceMemory: undefined,
  pointerCoarse: true,
  viewportWidth: 0,
  saveData: false,
  slowEffectiveType: false,
}

function detectWebGL(): boolean {
  try {
    const canvas = document.createElement("canvas")
    return !!(canvas.getContext("webgl2") || canvas.getContext("webgl"))
  } catch {
    return false
  }
}

/** Reads live browser signals. Client-only — returns the conservative SSR default on the server. */
export function readCapabilitySignals(): CapabilitySignals {
  if (typeof window === "undefined") return SSR_SIGNALS

  const nav = navigator as NavigatorWithHints
  const effectiveType = nav.connection?.effectiveType

  return {
    prefersReducedMotion: window.matchMedia("(prefers-reduced-motion: reduce)").matches,
    hasWebGL: detectWebGL(),
    hardwareConcurrency: nav.hardwareConcurrency,
    deviceMemory: nav.deviceMemory,
    pointerCoarse: window.matchMedia("(pointer: coarse)").matches,
    viewportWidth: window.innerWidth,
    saveData: nav.connection?.saveData === true,
    slowEffectiveType: effectiveType !== undefined && SLOW_EFFECTIVE_TYPES.has(effectiveType),
  }
}
