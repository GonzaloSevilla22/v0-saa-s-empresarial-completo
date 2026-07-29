"use client"

import { GatedSceneMount } from "@/components/three/GatedSceneMount"
import { HeroPoster } from "@/components/three/HeroPoster"

/** Stable, module-level reference — required by `GatedSceneMount` (only read once). */
const importHeroSceneCanvas = () => import("@/components/three/HeroSceneCanvas")

/**
 * PUBLIC mount point for the landing hero 3D accent — the ONLY hero-3D import
 * pages should use (task 2.9, reused by task 3.1's landing integration).
 * Safe to import eagerly: this file and `HeroPoster` never import
 * `@react-three/fiber`/`three` directly.
 *
 * Goes through `GatedSceneMount`, NOT a bare `loadScene`/`next/dynamic` call
 * — rendering a dynamic component unconditionally still downloads its chunk
 * regardless of internal gating (the bug this fixes, found via browser E2E
 * on this exact surface — see `GatedSceneMount`'s docstring). The entire 3D
 * graph (R3F, three, drei, `Lazy3DCanvas`, `HeroScene`) is reached
 * exclusively through that gate.
 */
export function HeroSceneMount({ className }: { className?: string }) {
  return (
    <GatedSceneMount
      importer={importHeroSceneCanvas}
      poster={<HeroPoster className={className} />}
      className={className}
    />
  )
}
