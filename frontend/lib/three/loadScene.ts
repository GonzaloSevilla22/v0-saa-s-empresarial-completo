import dynamic from "next/dynamic"
import type { ComponentType, ReactNode } from "react"

/**
 * The ONE way to lazy-load a 3D scene component (design.md D2, task 2.6).
 * Never call `next/dynamic` ad-hoc per scene — always go through this helper
 * so the two non-negotiable guardrails can't be forgotten:
 *  - `ssr: false` — WebGL doesn't exist server-side, and this also prevents
 *    a hydration mismatch (the client's first real render already knows the
 *    capability gate result; the server never does).
 *  - a `loading` fallback (normally a `Poster`) — so there is never a blank
 *    gap while the scene's chunk downloads, and the SAME static art also
 *    ends up being the terminal state when the capability gate disqualifies
 *    the device (see `Poster`'s docstring).
 *
 * @example
 * const HeroScene = loadScene(() => import("./HeroScene"), () => <HeroPoster />)
 */
export function loadScene<P extends object>(
  importer: () => Promise<{ default: ComponentType<P> }>,
  loading: () => ReactNode,
) {
  return dynamic(importer, { ssr: false, loading })
}
