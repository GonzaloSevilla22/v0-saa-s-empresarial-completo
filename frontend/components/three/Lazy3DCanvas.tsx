"use client"

import { Suspense, useEffect, useRef, useState, type ReactNode } from "react"
import { Canvas, type CanvasProps } from "@react-three/fiber"
import { AdaptiveDpr, AdaptiveEvents } from "@react-three/drei"
import { useCapabilityGate } from "@/hooks/three/useCapabilityGate"
import { SceneErrorBoundary } from "./SceneErrorBoundary"
import { cn } from "@/lib/utils"

export interface Lazy3DCanvasProps {
  /** Static poster — the ONE fallback for gate-disqualified, loading, and errored states. */
  poster: ReactNode
  /** Scene contents (meshes/lights/etc) mounted inside the R3F `<Canvas>`. */
  children: ReactNode
  /** Extra props forwarded to `<Canvas>` (camera, gl, dpr, …). `frameloop` is always `"demand"` — not overridable. */
  canvasProps?: Omit<CanvasProps, "frameloop">
  className?: string
  /** Reported when the scene throws during render (`SceneErrorBoundary`) — for logging only, never re-thrown. */
  onSceneError?: (error: unknown) => void
}

/**
 * Wrapper that turns any R3F scene into a guardrail-compliant 3D surface
 * (spec `immersive-3d-surfaces`):
 *  - Consumes the capability gate (`useCapabilityGate`) — disqualified
 *    devices never get an `IntersectionObserver`, never mount `<Canvas>`.
 *  - Mounts `<Canvas>` only once the container enters the viewport
 *    (Requirement "Carga fuera del critical path", Scenario "Montaje por
 *    viewport"), and unmounts it on exit — an unmounted R3F `<Canvas>` has no
 *    render loop, satisfying "pausar/desmontar el loop fuera de viewport"
 *    without needing an imperative pause API.
 *  - `frameloop="demand"`: even while mounted and visible, R3F only renders
 *    a frame when something invalidates it (vs. a constant 60fps loop) —
 *    scenes that animate every frame must call `useFrame`'s `invalidate()`
 *    or use drei's `<Loop>`/`useFrame` with `frameloop` awareness themselves.
 *  - `<Suspense fallback={poster}>` covers the gap while a scene's own async
 *    assets (if any) resolve.
 *  - `<SceneErrorBoundary fallback={poster}>` covers render failures.
 *  - The container is always `aria-hidden="true"` (Requirement
 *    "Accesibilidad del contenido 3D") — decorative only, in every state.
 *  - `<AdaptiveDpr>` + `<AdaptiveEvents>` (drei) on every scene automatically:
 *    when R3F detects dropped frames it "regresses" performance, and these
 *    respond by lowering the device pixel ratio (rendering fewer physical
 *    pixels) and throttling pointer-event raycasting — degrading RESOLUTION
 *    before FRAME RATE (spec Requirement "Presupuesto de performance",
 *    Scenario "Degradación de calidad antes que de FPS"). Applied here, not
 *    per-scene, so no scene author needs to remember to add it.
 */
export function Lazy3DCanvas({
  poster,
  children,
  canvasProps,
  className,
  onSceneError,
}: Lazy3DCanvasProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const [isInView, setIsInView] = useState(false)
  const gate = useCapabilityGate()

  useEffect(() => {
    // Disqualified (or not yet resolved): no point observing — reset and bail.
    if (!gate.qualifies) {
      setIsInView(false)
      return
    }

    const node = containerRef.current
    if (!node) return

    const observer = new IntersectionObserver(
      (entries) => setIsInView(entries[0]?.isIntersecting ?? false),
      { threshold: 0.1 },
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [gate.qualifies])

  const shouldRenderCanvas = gate.qualifies && isInView

  return (
    <div ref={containerRef} aria-hidden="true" className={cn(className)}>
      {shouldRenderCanvas ? (
        <SceneErrorBoundary fallback={poster} onError={onSceneError}>
          <Suspense fallback={poster}>
            <Canvas frameloop="demand" dpr={[1, 2]} {...canvasProps}>
              <AdaptiveDpr pixelated />
              <AdaptiveEvents />
              {children}
            </Canvas>
          </Suspense>
        </SceneErrorBoundary>
      ) : (
        poster
      )}
    </div>
  )
}
