/**
 * Tests for `Poster` (components/three/Poster.tsx) — the single static
 * fallback art used for every 3D surface state: `next/dynamic`'s `loading`,
 * the `<Suspense>` fallback while assets load, the capability-gate
 * disqualified state, and the `SceneErrorBoundary` fallback (spec
 * `immersive-3d-surfaces`).
 *
 * Cycle: RED (component doesn't exist yet) → GREEN → TRIANGULATE → REFACTOR.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { Poster } from "@/components/three/Poster"

describe("Poster", () => {
  // ── RED/GREEN: happy path — single theme-agnostic poster ────────────────
  it("renders a single decorative, aria-hidden image when no dark variant is given", () => {
    const { container } = render(<Poster src="/3d/hero-poster.svg" width={640} height={480} />)

    const wrapper = container.firstElementChild as HTMLElement
    expect(wrapper).toHaveAttribute("aria-hidden", "true")

    const images = screen.getAllByRole("presentation", { hidden: true })
    expect(images).toHaveLength(1)
    expect(images[0]).toHaveAttribute("alt", "")
  })

  // ── TRIANGULATE: theme-aware — renders both variants, CSS toggles visibility ──
  it("renders both light and dark variants (CSS-toggled) when srcDark is given", () => {
    render(
      <Poster
        src="/3d/hero-poster-light.svg"
        srcDark="/3d/hero-poster-dark.svg"
        width={640}
        height={480}
      />,
    )

    const images = screen.getAllByRole("presentation", { hidden: true })
    expect(images).toHaveLength(2)
    expect(images[0].className).toContain("dark:hidden")
    expect(images[1].className).toContain("dark:block")
  })

  // ── fix/login-3d-visible (MAJOR 1/MINOR 2 de la revisión adversarial) ──
  // `fill` es opt-in: sin él, ningún caller existente de `Poster` (hoy,
  // `HeroPoster`) cambia de tamaño — regresión guard contra volver a hacerlo
  // default/incondicional (lo que movería el render de la landing sin que
  // nadie lo pida ni lo pruebe).
  it("does NOT scale the image to its container by default (fill omitted) — preserves HeroPoster's intrinsic sizing", () => {
    render(<Poster src="/3d/hero-poster.svg" width={640} height={480} />)

    const [image] = screen.getAllByRole("presentation", { hidden: true })
    expect(image.className).not.toMatch(/\bh-full\b/)
    expect(image.className).not.toMatch(/\bw-full\b/)
  })

  // MAJOR 1: el spec de geometría del harness (login-3d-scene-geometry.spec.ts)
  // sólo mide la CAJA decorativa, nunca el dibujo — revertir esta clase en
  // `Poster` dejaba ese spec en verde con el póster clavado a 400x400 e
  // igual de tapado que antes del fix. Este test fija el contrato que ese
  // spec asume, en las DOS variantes (única y por-tema) que `AuthPoster` usa.
  it("scales the image to fill its container when fill is set, on every rendered variant", () => {
    const { rerender } = render(<Poster src="/3d/auth-poster.svg" width={400} height={400} fill />)
    const [single] = screen.getAllByRole("presentation", { hidden: true })
    expect(single.className).toMatch(/\bh-full\b/)
    expect(single.className).toMatch(/\bw-full\b/)
    expect(single.className).toMatch(/\bobject-contain\b/)

    rerender(
      <Poster
        src="/3d/auth-poster-light.svg"
        srcDark="/3d/auth-poster-dark.svg"
        width={400}
        height={400}
        fill
      />,
    )
    const [light, dark] = screen.getAllByRole("presentation", { hidden: true })
    for (const image of [light, dark]) {
      expect(image.className).toMatch(/\bh-full\b/)
      expect(image.className).toMatch(/\bw-full\b/)
      expect(image.className).toMatch(/\bobject-contain\b/)
    }
  })
})
