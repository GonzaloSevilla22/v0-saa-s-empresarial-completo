"use client"

import { Lazy3DCanvas } from "@/components/three/Lazy3DCanvas"
import { AuthPoster } from "@/components/three/AuthPoster"
import AuthScene from "@/components/three/AuthScene"

/**
 * Combines `Lazy3DCanvas` with `AuthScene` — same split-file reasoning as
 * `HeroSceneCanvas.tsx` (keeps the R3F/three import out of any eagerly-
 * loaded module; only reached via `AuthSceneMount`'s `GatedSceneMount`).
 */
export default function AuthSceneCanvas({ className }: { className?: string }) {
  return (
    <Lazy3DCanvas
      poster={<AuthPoster />}
      className={className}
      canvasProps={{ camera: { position: [0, 0, 5], fov: 50 } }}
    >
      <AuthScene />
    </Lazy3DCanvas>
  )
}
