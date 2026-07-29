"use client"

import { useEffect, useState } from "react"
import {
  evaluateCapabilityGate,
  readCapabilitySignals,
  type CapabilityGateResult,
} from "@/lib/three/capabilityGate"

/**
 * SSR-safe initial value: `qualifies: false` so the very first client render
 * matches the server render exactly (no hydration mismatch) — same pattern
 * as `usePrefersReducedMotion`/`useMediaQuery` (hooks/ui/use-media-query.ts),
 * which also default to the "no" answer until mounted. The gate never shows
 * 3D during SSR anyway (D2 mandates `next/dynamic({ ssr: false })`), so this
 * default is also the *correct* answer, not just a hydration workaround.
 * The `reason` here is a placeholder — it does not claim the user actually
 * has reduced-motion set, only that the real signals haven't been read yet.
 */
const PENDING_RESULT: CapabilityGateResult = { qualifies: false, reason: "reduced-motion" }

/**
 * Reactive read of the 3D capability gate (design.md D5). Consumed by
 * `components/three/Lazy3DCanvas.tsx` to decide between mounting the
 * `<Canvas>` and rendering the static poster.
 *
 * Re-evaluates on mount, on a live `prefers-reduced-motion` OS toggle, and on
 * viewport resize (covers rotating a tablet or resizing a desktop window
 * across the mobile breakpoint) — WebGL support and hardware hints don't
 * change during a session, so they're only read once per (re)evaluation.
 */
export function useCapabilityGate(): CapabilityGateResult {
  const [result, setResult] = useState<CapabilityGateResult>(PENDING_RESULT)

  useEffect(() => {
    const reevaluate = () => setResult(evaluateCapabilityGate(readCapabilitySignals()))
    reevaluate()

    const reducedMotionMql = window.matchMedia("(prefers-reduced-motion: reduce)")
    reducedMotionMql.addEventListener("change", reevaluate)
    window.addEventListener("resize", reevaluate)
    return () => {
      reducedMotionMql.removeEventListener("change", reevaluate)
      window.removeEventListener("resize", reevaluate)
    }
  }, [])

  return result
}
