"use client"

import { useEffect, useState } from "react"
import { useCapabilityGate } from "@/hooks/three/useCapabilityGate"
import { loadScene } from "@/lib/three/loadScene"
import type { CelebrationVariant } from "@/lib/three/celebrationTheme"
import { cn } from "@/lib/utils"

/** Stable, module-level reference — required by `loadScene` (created once, not per-render). */
const importCelebrationCanvas = () => import("@/components/three/CelebrationCanvas")
const CelebrationCanvas = loadScene(importCelebrationCanvas, () => null)

const DEFAULT_DURATION_MS = 1800

export interface Celebration3DProps {
  /** Toggle on to fire the celebration; the component auto-hides itself afterward — the caller does not need to toggle it back off. */
  show: boolean
  variant?: CelebrationVariant
  /** How long the burst stays mounted before auto-unmounting. */
  durationMs?: number
  className?: string
}

/**
 * On-demand, ephemeral 3D burst for "venta cerrada" (task 3.5) / "meta
 * alcanzada" (task 3.6) — the 3D counterpart of the Fase A 2D `Celebrate`
 * wrapper (`components/motion/Celebrate.tsx`), same "purely presentational,
 * mounted/unmounted by the caller via `show`, never coupled to
 * handlers/queries/mutations" contract.
 *
 * Guardrails (spec `immersive-3d-surfaces`):
 *  - Gated by `useCapabilityGate()` BEFORE ever rendering the dynamically-
 *    imported `CelebrationCanvas` — a disqualified device (incl.
 *    `prefers-reduced-motion: reduce`) gets **no burst at all**, not a
 *    static poster substitute: an ephemeral firework has no meaningful
 *    static equivalent, and the calling surface (POS/dashboard) already
 *    shows its own 2D success feedback independent of this — "sin burst"
 *    per task 3.5, not "poster instead of burst".
 *  - `aria-hidden` + `pointer-events-none` fixed overlay — never intercepts
 *    clicks, never blocks the checkout/next-action flow.
 *  - Self-unmounts after `durationMs` — the caller never needs a second
 *    `setState` to dismiss it.
 */
export function Celebration3D({
  show,
  variant = "sale",
  durationMs = DEFAULT_DURATION_MS,
  className,
}: Celebration3DProps) {
  const gate = useCapabilityGate()
  const [visible, setVisible] = useState(false)

  useEffect(() => {
    if (!show || !gate.qualifies) {
      setVisible(false)
      return
    }
    setVisible(true)
    const timer = setTimeout(() => setVisible(false), durationMs)
    return () => clearTimeout(timer)
  }, [show, gate.qualifies, durationMs])

  if (!visible) return null

  return (
    <div
      aria-hidden="true"
      className={cn(
        "pointer-events-none fixed inset-0 z-[60] flex items-center justify-center",
        className,
      )}
    >
      <div className="h-64 w-64">
        <CelebrationCanvas variant={variant} />
      </div>
    </div>
  )
}
