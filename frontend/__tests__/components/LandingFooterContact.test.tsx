/**
 * Tests del link "Contacto" del footer de la landing (`LandingPageFull`) —
 * follow-up del change `landing-whatsapp-fab`: el footer tenía ~12 links
 * muertos (`href="#"`) y "Contacto" es el único que gana destino real
 * (el WhatsApp de ALIADATA), vía la prop `contactWhatsAppUrl` que computa
 * el server (`app/page.tsx`) desde `ALIADATA_WHATSAPP_PHONE`.
 *
 * Se mockea `HeroSceneMount` (la escena 3D es irrelevante acá y jsdom no
 * tiene WebGL). `matchMedia` se stubea como en FadeIn.test.tsx.
 *
 * Ciclo: RED (la prop no existe) → GREEN → TRIANGULATE (degradación).
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { vi } from "vitest"

vi.mock("@/components/three/HeroSceneMount", () => ({
  HeroSceneMount: () => null,
}))

import { LandingPageFull } from "@/components/landing/LandingPageFull"

function installMatchMediaStub() {
  window.matchMedia = (query: string): MediaQueryList =>
    ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }) as MediaQueryList
}

const WA_URL = "https://wa.me/5492617635174?text=Hola"

describe("LandingPageFull — link Contacto del footer", () => {
  // ── RED/GREEN: con URL configurada, Contacto apunta al WhatsApp ───────────
  it("points the footer Contacto link at the WhatsApp URL when provided", () => {
    installMatchMediaStub()
    render(<LandingPageFull sections={[]} contactWhatsAppUrl={WA_URL} />)

    const link = screen.getByRole("link", { name: /contacto/i })
    expect(link).toHaveAttribute("href", WA_URL)
  })

  // ── TRIANGULATE: enlace saliente protegido (mismo contrato que el FAB) ────
  it("opens the Contacto link in a new tab with noopener and noreferrer", () => {
    installMatchMediaStub()
    render(<LandingPageFull sections={[]} contactWhatsAppUrl={WA_URL} />)

    const link = screen.getByRole("link", { name: /contacto/i })
    expect(link).toHaveAttribute("target", "_blank")
    const rel = link.getAttribute("rel") ?? ""
    expect(rel).toContain("noopener")
    expect(rel).toContain("noreferrer")
  })

  // ── TRIANGULATE: degradación — sin URL, el footer queda como estaba hoy ───
  it("keeps the dead '#' link and no wa.me href when the URL is not configured", () => {
    installMatchMediaStub()
    const { container } = render(<LandingPageFull sections={[]} />)

    const link = screen.getByRole("link", { name: /^contacto$/i })
    expect(link).toHaveAttribute("href", "#")
    expect(container.innerHTML).not.toContain("wa.me")
  })

  // ── TRIANGULATE: los otros links del footer no cambian ────────────────────
  it("leaves the other Empresa links untouched", () => {
    installMatchMediaStub()
    render(<LandingPageFull sections={[]} contactWhatsAppUrl={WA_URL} />)

    for (const label of ["Nosotros", "Blog", "Comunidad"]) {
      expect(screen.getByRole("link", { name: label })).toHaveAttribute("href", "#")
    }
  })
})
