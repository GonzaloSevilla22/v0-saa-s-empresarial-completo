"use client"

import { useEffect, useRef, useState } from "react"
import { findCrossedMilestone } from "@/lib/three/goalMilestone"

/**
 * Wires `findCrossedMilestone` to a component's already-fetched KPI value —
 * "meta alcanzada" (task 3.6). Purely presentational: the caller owns the
 * value and its fetch (e.g. `app/(dashboard)/dashboard/page.tsx`'s existing
 * `financials`/`loadingKpis` state) — this hook only derives a UI trigger,
 * never fetches or mutates anything itself.
 *
 * Policy: the FIRST value received once `isLoading` turns `false` becomes
 * the baseline and is NEVER itself reported as a crossing. Reasoning: a
 * plain "previous vs current" comparison seeded at mount (initial value is
 * usually `0` before the fetch resolves) would report a "crossing" on every
 * single page load/reload where today's KPI already exceeds a threshold —
 * stale and not something to actually celebrate. Only a LATER increase past
 * a threshold, relative to that established baseline (e.g. a live re-fetch
 * showing more sales while the user is still looking at the page), fires.
 */
export function useGoalMilestone(
  value: number,
  thresholds: readonly number[],
  isLoading: boolean,
): number | null {
  const baselineRef = useRef<number | null>(null)
  const [crossed, setCrossed] = useState<number | null>(null)

  useEffect(() => {
    if (isLoading) return

    if (baselineRef.current === null) {
      baselineRef.current = value
      return
    }

    const milestone = findCrossedMilestone(baselineRef.current, value, thresholds)
    baselineRef.current = value
    if (milestone !== null) setCrossed(milestone)
  }, [value, thresholds, isLoading])

  return crossed
}
