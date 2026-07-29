"use client"

import { useEffect, useMemo, useRef, useState, type ComponentType, type ReactNode } from "react"
import { useCapabilityGate } from "@/hooks/three/useCapabilityGate"
import { loadScene } from "@/lib/three/loadScene"
import { cn } from "@/lib/utils"

export interface GatedSceneMountProps {
  /**
   * Importer for the heavy scene module (its default export is rendered once
   * gating passes). MUST be a stable reference (defined at module scope, e.g.
   * `() => import("@/components/three/HeroSceneCanvas")`) — it is only read
   * once (`useMemo`, empty deps) to build the `next/dynamic` component.
   */
  importer: () => Promise<{ default: ComponentType<{ className?: string }> }>
  /** Static poster — the ONLY thing rendered/downloaded until gating passes. */
  poster: ReactNode
  className?: string
}

/**
 * The ONE way pages should mount a lazy 3D scene. Fixes a real gap found via
 * browser E2E (task 2.10) on the landing pilot: rendering a
 * `next/dynamic({ssr:false})`-wrapped scene unconditionally still downloads
 * its chunk as soon as that component renders — `next/dynamic` triggers the
 * fetch from ITS OWN render, regardless of what the component internally
 * decides to show. `Lazy3DCanvas`'s gate/viewport check (inside the
 * dynamically-imported module) only decides Canvas-vs-poster AFTER the chunk
 * had already downloaded — too late for spec `immersive-3d-surfaces`'s
 * Save-Data/mobile Scenarios, whose entire point is to avoid the download.
 *
 * `GatedSceneMount` checks the capability gate AND viewport BEFORE ever
 * rendering the dynamically-imported component, so a disqualified or
 * below-the-fold visitor never triggers the fetch — confirmed via
 * `__tests__/components/three/GatedSceneMount.test.tsx` (the importer mock
 * is asserted `not.toHaveBeenCalled()` in the disqualified/not-in-view cases).
 */
export function GatedSceneMount({ importer, poster, className }: GatedSceneMountProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const [isInView, setIsInView] = useState(false)
  const gate = useCapabilityGate()

  useEffect(() => {
    if (!gate.qualifies) {
      setIsInView(false)
      return
    }
    const node = containerRef.current
    if (!node) return

    const observer = new IntersectionObserver(
      (entries) => setIsInView(entries[0]?.isIntersecting ?? false),
      { threshold: 0.1, rootMargin: "200px" },
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [gate.qualifies])

  // Created once — a stable component identity so React never remounts /
  // re-triggers the import purely because of a parent re-render. Goes
  // through `loadScene` (task 2.6's `next/dynamic({ssr:false, loading})`
  // convention) — the SAME helper every scene uses, not a bespoke `dynamic()`
  // call here.
  // eslint-disable-next-line react-hooks/exhaustive-deps
  const Scene = useMemo(() => loadScene(importer, () => <>{poster}</>), [])

  const shouldLoad = gate.qualifies && isInView

  return (
    <div ref={containerRef} aria-hidden="true" className={cn("pointer-events-none", className)}>
      {shouldLoad ? <Scene className={className} /> : poster}
    </div>
  )
}
