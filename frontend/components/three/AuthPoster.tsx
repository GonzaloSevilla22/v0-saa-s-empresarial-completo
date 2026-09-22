import { Poster } from "@/components/three/Poster"

const AUTH_POSTER_SIZE = 400

/**
 * Static fallback for the login/registro accompaniment scene (task 3.2).
 * Same "lightweight, no R3F/three import" contract as `HeroPoster` — self-
 * authored SVG (PO sign-off, no downloaded assets), theme-aware via
 * `Poster`'s CSS `dark:` variant switching.
 *
 * fix/login-3d-visible: `fill` — el ÚNICO caller de `Poster` que necesita el
 * dibujo escalando con su caja decorativa (`AUTH_SCENE_BOX_CLASS`, hasta
 * 860x860) en vez de clavado a su intrínseco 400x400. `HeroPoster` no lo
 * pasa — su render en la landing no cambia.
 */
export function AuthPoster({ className }: { className?: string }) {
  return (
    <Poster
      src="/3d/auth-poster-light.svg"
      srcDark="/3d/auth-poster-dark.svg"
      width={AUTH_POSTER_SIZE}
      height={AUTH_POSTER_SIZE}
      className={className}
      fill
    />
  )
}
