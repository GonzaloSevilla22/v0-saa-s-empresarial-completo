import Image from "next/image"
import { cn } from "@/lib/utils"

export interface PosterProps {
  /** Poster shown in light theme (or always, when `srcDark` is omitted). */
  src: string
  /** Optional dark-theme variant (design.md D9 — "usa un poster por tema"). */
  srcDark?: string
  width: number
  height: number
  className?: string
  /** Forwarded to `next/image` — set for the poster that is also the LCP element. */
  priority?: boolean
}

/**
 * Static fallback art for a 3D surface (spec `immersive-3d-surfaces`). The
 * SAME component/asset serves every fallback state — there is no separate
 * "loading" vs "disqualified" vs "errored" art:
 *  - `next/dynamic({ ssr:false }).loading`
 *  - the `<Suspense>` fallback while a scene's assets load (`Lazy3DCanvas`)
 *  - the terminal state when the capability gate disqualifies the device
 *  - the `SceneErrorBoundary` fallback after a render failure
 *
 * `aria-hidden="true"` + empty `alt`: purely decorative, never announced by
 * assistive tech (spec Requirement "Accesibilidad del contenido 3D").
 *
 * Theme-aware via CSS `dark:` classes (design.md D9), not `useTheme()` — the
 * correct variant is visible on the very first paint, no client-only theme
 * hook to resolve first.
 */
// fix/login-3d-visible: el `width`/`height` de arriba son el tamaño INTRÍNSECO
// que `next/image` exige (metadata/aspect, nunca se descarga otra cosa al ser
// SVG). El tamaño RENDERIZADO lo decide el contenedor (el `className` del
// caller, p. ej. `AuthSceneMount`) — `h-full w-full` + `object-contain` hacen
// que el dibujo escale con su caja (más grande en desktop, más chica en
// mobile) preservando aspecto, en vez de quedar clavado a 400x400 y anclado
// arriba-izquierda dentro de una caja más grande sin centrar.
const RESPONSIVE_IMAGE_CLASS = "h-full w-full object-contain"

export function Poster({ src, srcDark, width, height, className, priority }: PosterProps) {
  if (!srcDark) {
    return (
      <div aria-hidden="true" className={cn("pointer-events-none select-none", className)}>
        <Image
          src={src}
          alt=""
          width={width}
          height={height}
          priority={priority}
          unoptimized={src.endsWith(".svg")}
          className={RESPONSIVE_IMAGE_CLASS}
        />
      </div>
    )
  }

  return (
    <div aria-hidden="true" className={cn("pointer-events-none select-none", className)}>
      <Image
        src={src}
        alt=""
        width={width}
        height={height}
        priority={priority}
        unoptimized={src.endsWith(".svg")}
        className={cn(RESPONSIVE_IMAGE_CLASS, "block dark:hidden")}
      />
      <Image
        src={srcDark}
        alt=""
        width={width}
        height={height}
        priority={priority}
        unoptimized={srcDark.endsWith(".svg")}
        className={cn(RESPONSIVE_IMAGE_CLASS, "hidden dark:block")}
      />
    </div>
  )
}
