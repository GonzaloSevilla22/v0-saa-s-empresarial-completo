/**
 * Render tests for TutorialVideo — the shared facade player used both in the
 * landing "Aprendé a usar ALIADATA" section and the dashboard's contextual
 * "Ver tutorial" modal.
 *
 * 2026-07-29 (fix CSP, decisión PO): el player es un FACADE PROPIO sin
 * scripts externos — la CSP de prod bloqueaba el script de lite-youtube
 * (cdn.jsdelivr.net) que usaba @next/third-parties. Estado inicial: botón
 * accesible con la miniatura de ytimg (img-src ya permite https:) + ícono
 * de play; al click se monta el <iframe> de youtube-nocookie.com
 * (permitido en frame-src) con autoplay.
 *
 * Cycle: RED → GREEN → TRIANGULATE
 */

import { describe, it, expect } from "vitest"
import { render, screen, fireEvent } from "@testing-library/react"
import { TutorialVideo } from "@/components/shared/TutorialVideo"

describe("TutorialVideo — facade propio (sin scripts externos)", () => {
  // ── RED → GREEN: estado inicial = miniatura + botón accesible, SIN iframe ──
  it("renders the ytimg thumbnail for the videoId and an accessible play button, with NO iframe", () => {
    const { container } = render(
      <TutorialVideo youtubeVideoId="dQw4w9WgXcQ" title="Cómo registrar una venta" />
    )
    const img = container.querySelector("img")
    expect(img).not.toBeNull()
    expect(img?.getAttribute("src")).toBe("https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    expect(
      screen.getByRole("button", { name: /cómo registrar una venta/i })
    ).toBeInTheDocument()
    expect(container.querySelector("iframe")).toBeNull()
  })

  // ── TRIANGULATE: otra id → otra miniatura (no hardcodeado) ─────────────
  it("builds the thumbnail URL from the given videoId (not hardcoded)", () => {
    const { container } = render(
      <TutorialVideo youtubeVideoId="C_SUggjXdkw" title="Onboarding" />
    )
    expect(container.querySelector("img")?.getAttribute("src")).toBe(
      "https://i.ytimg.com/vi/C_SUggjXdkw/hqdefault.jpg"
    )
  })

  // ── RED → GREEN: click → iframe de youtube-nocookie con autoplay y rel=0 ──
  it("mounts the youtube-nocookie iframe with autoplay=1&rel=0 and allowFullScreen on click", () => {
    const { container } = render(
      <TutorialVideo youtubeVideoId="dQw4w9WgXcQ" title="Cómo registrar una venta" />
    )
    fireEvent.click(screen.getByRole("button", { name: /cómo registrar una venta/i }))

    const iframe = container.querySelector("iframe")
    expect(iframe).not.toBeNull()
    expect(iframe?.getAttribute("src")).toBe(
      "https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?autoplay=1&rel=0"
    )
    expect(iframe?.hasAttribute("allowfullscreen")).toBe(true)
    expect(iframe?.getAttribute("title")).toBe("Cómo registrar una venta")
    // La miniatura/botón desaparecen: el iframe ocupa el contenedor
    expect(container.querySelector("img")).toBeNull()
    expect(screen.queryByRole("button", { name: /cómo registrar una venta/i })).not.toBeInTheDocument()
  })

  // ── TRIANGULATE: sin title, el facade sigue siendo accesible ───────────
  it("stays accessible without a title (generic aria-label and iframe title)", () => {
    const { container } = render(<TutorialVideo youtubeVideoId="abc123XYZ99" />)
    const button = screen.getByRole("button", { name: /video tutorial/i })
    fireEvent.click(button)
    expect(container.querySelector("iframe")?.getAttribute("title")).toMatch(/video tutorial/i)
  })

  // ── TRIANGULATE: 16:9 aspect-ratio container (Radix padding-bottom trick) ──
  it("wraps the player in a 16:9 aspect-ratio container", () => {
    const { container } = render(<TutorialVideo youtubeVideoId="dQw4w9WgXcQ" />)
    const aspectWrapper = container.querySelector<HTMLElement>("[data-radix-aspect-ratio-wrapper]")
    expect(aspectWrapper).not.toBeNull()
    // 16:9 → paddingBottom = 100 / (16/9) = 56.25%
    expect(aspectWrapper?.style.paddingBottom).toBe("56.25%")
  })
})
