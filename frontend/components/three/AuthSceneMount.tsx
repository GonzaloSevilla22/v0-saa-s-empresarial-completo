"use client"

import { GatedSceneMount } from "@/components/three/GatedSceneMount"
import { AuthPoster } from "@/components/three/AuthPoster"

/** Stable, module-level reference — required by `GatedSceneMount` (only read once). */
const importAuthSceneCanvas = () => import("@/components/three/AuthSceneCanvas")

/**
 * PUBLIC mount point for the login/registro accompaniment 3D accent (task
 * 3.2) — the ONLY import `app/auth/login` and `app/auth/register` should
 * use. Same `GatedSceneMount` contract as `HeroSceneMount` — gate+viewport
 * checked BEFORE the R3F/three chunk is ever downloaded.
 */
export function AuthSceneMount({ className }: { className?: string }) {
  return (
    <GatedSceneMount
      importer={importAuthSceneCanvas}
      poster={<AuthPoster className={className} />}
      className={className}
    />
  )
}
