"use client"

import { Lazy3DCanvas } from "@/components/three/Lazy3DCanvas"
import { HeroPoster } from "@/components/three/HeroPoster"
import HeroScene from "@/components/three/HeroScene"

/**
 * Combines `Lazy3DCanvas` (which imports `@react-three/fiber`'s `Canvas`)
 * with the actual `HeroScene` mesh content. Deliberately its OWN module,
 * separate from the thin `HeroSceneMount` — `Lazy3DCanvas.tsx` imports
 * `Canvas` from `@react-three/fiber` at the top of the file, so importing
 * `Lazy3DCanvas` EAGERLY anywhere would pull the whole R3F/three runtime into
 * that route's first-load JS regardless of how lazily `HeroScene` itself is
 * loaded. `HeroSceneMount.tsx` reaches this file exclusively through
 * `loadScene()` (`next/dynamic({ ssr:false })`) so the entire graph — R3F,
 * three, drei, `Lazy3DCanvas`, `HeroScene` — stays out of the critical path
 * (design.md D2, task 2.6/2.9). Verified via `pnpm build` route/shared-chunk
 * output, not just by construction.
 */
export default function HeroSceneCanvas({ className }: { className?: string }) {
  return (
    <Lazy3DCanvas
      poster={<HeroPoster />}
      className={className}
      canvasProps={{ camera: { position: [0, 0, 6], fov: 50 } }}
    >
      <HeroScene />
    </Lazy3DCanvas>
  )
}
