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
        className="block dark:hidden"
      />
      <Image
        src={srcDark}
        alt=""
        width={width}
        height={height}
        priority={priority}
        unoptimized={srcDark.endsWith(".svg")}
        className="hidden dark:block"
      />
    </div>
  )
}
