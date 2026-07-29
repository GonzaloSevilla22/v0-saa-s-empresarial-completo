import { Poster } from "@/components/three/Poster"

const HERO_POSTER_SIZE = 400

/**
 * Static fallback art for the landing hero 3D accent (task 2.9). Deliberately
 * lightweight — no `@react-three/fiber`/`three` import here — this is the
 * component rendered as `next/dynamic`'s `loading` (before the 3D chunk
 * downloads), so it must be cheap to include in the eager bundle of every
 * page that shows the hero.
 *
 * SVG self-authored low-poly art (`public/3d/hero-poster-{light,dark}.svg`),
 * not a downloaded/commissioned asset (PO sign-off, design.md Open Question
 * 5). Theme-aware via `Poster`'s CSS `dark:` variant switching.
 */
export function HeroPoster({ className }: { className?: string }) {
  return (
    <Poster
      src="/3d/hero-poster-light.svg"
      srcDark="/3d/hero-poster-dark.svg"
      width={HERO_POSTER_SIZE}
      height={HERO_POSTER_SIZE}
      className={className}
    />
  )
}
