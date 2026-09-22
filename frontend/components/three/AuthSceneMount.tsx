"use client"

import { GatedSceneMount } from "@/components/three/GatedSceneMount"
import { AuthPoster } from "@/components/three/AuthPoster"

/** Stable, module-level reference — required by `GatedSceneMount` (only read once). */
const importAuthSceneCanvas = () => import("@/components/three/AuthSceneCanvas")

/**
 * fix/login-3d-visible: tamaño de la caja decorativa, compartido por
 * `app/auth/login` y `app/auth/register` (una sola fuente — regla "reutilización
 * antes que repetición" — en vez de repetir el string en cada página).
 *
 * Antes esta caja medía 480x480 fijos y quedaba centrada EXACTAMENTE sobre el
 * `Card` del formulario (~448x700, `bg-card` opaco): quedaba tapada casi al
 * 100%. Decisión del PO: "que quede detrás y sobresalga" — el `Card` no
 * cambia de lugar/tamaño; esta caja crece para asomar alrededor:
 *  - Desktop (`md:` y superior): 860x860 — el `Card` sigue fijo en 448px de
 *    ancho (`max-w-md`), así que sobresale ~206px por lado (holgado sobre el
 *    piso de e2e/harness/login-3d-scene-geometry.spec.ts, 120px).
 *  - Mobile: 360x360 — el `Card` ocupa casi todo el ancho ahí, así que no hay
 *    margen para asomar a los lados (ni falta: el overlay que la centra tiene
 *    `overflow-hidden` en su ancestro, cero scroll horizontal). Asoma en
 *    VERTICAL en cambio, vía el cambio de alineación del overlay (`items-start`
 *    en mobile, `md:items-center` en desktop — ver `AuthSceneMount`'s callers).
 */
export const AUTH_SCENE_BOX_CLASS = "h-[360px] w-[360px] md:h-[860px] md:w-[860px]"

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
