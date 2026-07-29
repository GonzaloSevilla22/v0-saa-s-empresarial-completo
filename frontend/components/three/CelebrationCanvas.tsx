"use client"

import { Lazy3DCanvas } from "@/components/three/Lazy3DCanvas"
import CelebrationScene from "@/components/three/CelebrationScene"
import type { CelebrationVariant } from "@/lib/three/celebrationTheme"

/**
 * Combines `Lazy3DCanvas` (imports `@react-three/fiber`'s `Canvas`) with the
 * celebration burst content — same split-file reasoning as
 * `HeroSceneCanvas.tsx` (keeps the R3F/three import out of any eagerly-
 * loaded module; only reached via `Celebration3D`'s `loadScene` call).
 *
 * No `poster` is meaningful for an ephemeral burst (see `Celebration3D`'s
 * docstring) — `null` is fine: `Lazy3DCanvas` only shows it for the brief
 * gap before this already-downloaded chunk's own IntersectionObserver
 * confirms the (always-visible, `position:fixed`) overlay is "in view".
 */
export default function CelebrationCanvas({ variant }: { variant: CelebrationVariant }) {
  return (
    <Lazy3DCanvas poster={null} canvasProps={{ camera: { position: [0, 0, 5], fov: 55 } }}>
      <CelebrationScene variant={variant} />
    </Lazy3DCanvas>
  )
}
