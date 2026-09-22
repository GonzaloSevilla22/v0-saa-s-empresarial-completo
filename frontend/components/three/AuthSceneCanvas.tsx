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
      // fix/login-3d-visible (MINOR 4 de la revisión adversarial): la caja
      // decorativa creció de 480x480 a 860x860 en desktop (~3.2x los píxeles
      // por frame con el `dpr={[1,2]}` default de `Lazy3DCanvas`). Tope propio
      // acá (no en `Lazy3DCanvas` — no toca `HeroSceneCanvas`, que sigue en su
      // caja original de 380/420): esta escena es puramente decorativa, un
      // dpr más bajo no se nota detrás de un formulario.
      canvasProps={{ camera: { position: [0, 0, 5], fov: 50 }, dpr: [1, 1.5] }}
    >
      <AuthScene />
    </Lazy3DCanvas>
  )
}
