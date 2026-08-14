/**
 * Tests de la sección de precios de la landing (`Pricing()` dentro de
 * `LandingPageFull`) con el tier Empresa — change `plan-empresa-contacto`,
 * design.md D3.
 *
 * La card Empresa se monta DEBAJO de la grilla de 4 planes, a lo ancho del
 * contenedor — nunca como una quinta columna. Sin `enterpriseWhatsAppUrl`
 * (número no configurado) la card no se renderiza y los 4 planes quedan
 * exactamente como estaban (D6).
 *
 * Todas las búsquedas se acotan a `#pricing` con `within`: el footer YA tiene
 * una columna titulada "Empresa" (`Nosotros`/`Blog`/`Comunidad`), así que
 * buscar el texto "Empresa" sin acotar matchea ese heading del footer, no la
 * card del tier — la primera corrida RED de este archivo lo confirmó.
 *
 * Se mockea `HeroSceneMount` (escena 3D irrelevante acá, sin WebGL en jsdom)
 * y se stubea `matchMedia`, igual que `LandingFooterContact.test.tsx`.
 *
 * Ciclo: RED (la prop no existe) → GREEN → TRIANGULATE.
 */

import { describe, it, expect } from "vitest"
import { render, screen, within } from "@testing-library/react"
import { vi } from "vitest"

vi.mock("@/components/three/HeroSceneMount", () => ({
  HeroSceneMount: () => null,
}))

import { LandingPageFull } from "@/components/landing/LandingPageFull"
import { ENTERPRISE_TIER } from "@/lib/enterprise-tier"

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

function getPricingSection(): HTMLElement {
  const section = document.getElementById("pricing")
  if (!section) throw new Error("#pricing section not found")
  return section
}

const ENTERPRISE_URL = "https://wa.me/5492617635174?text=Empresa"
const FOUR_PLANS = ["Gratis", "Inicial", "Avanzado", "Pro"]

describe("LandingPageFull — sección de precios con el tier Empresa", () => {
  // ── RED/GREEN: con la URL provista, se ven los 4 planes + la card Empresa ──
  it("renders the 4 plans plus the Empresa card when enterpriseWhatsAppUrl is provided", () => {
    installMatchMediaStub()
    render(<LandingPageFull sections={[]} enterpriseWhatsAppUrl={ENTERPRISE_URL} />)
    const pricing = within(getPricingSection())

    for (const name of FOUR_PLANS) {
      expect(pricing.getByRole("heading", { name })).toBeInTheDocument()
    }
    expect(pricing.getByText(ENTERPRISE_TIER.tagline)).toBeInTheDocument()

    const link = pricing.getByRole("link", { name: ENTERPRISE_TIER.ctaAccessibleLabel })
    expect(link).toHaveAttribute("href", ENTERPRISE_URL)
  })

  // ── TRIANGULATE (a): sin URL, la card no aparece y los 4 planes siguen (D6) ─
  it("omits the Empresa card and keeps the 4 plans when the URL is not provided", () => {
    installMatchMediaStub()
    render(<LandingPageFull sections={[]} />)
    const pricing = within(getPricingSection())

    for (const name of FOUR_PLANS) {
      expect(pricing.getByRole("heading", { name })).toBeInTheDocument()
    }
    expect(pricing.queryByText(ENTERPRISE_TIER.tagline)).toBeNull()
    expect(pricing.queryByRole("link", { name: ENTERPRISE_TIER.ctaAccessibleLabel })).toBeNull()
  })

  // ── TRIANGULATE (b): los 4 planes conservan nombre, precio y CTA a /auth/login
  it("keeps the 4 plans' name, price and CTA to /auth/login untouched", () => {
    installMatchMediaStub()
    render(<LandingPageFull sections={[]} enterpriseWhatsAppUrl={ENTERPRISE_URL} />)
    const pricing = within(getPricingSection())

    expect(pricing.getByText("$0")).toBeInTheDocument()
    expect(pricing.getByText("$24.900")).toBeInTheDocument()
    expect(pricing.getByText("$34.900")).toBeInTheDocument()
    expect(pricing.getByText("$69.900")).toBeInTheDocument()

    const loginLinks = pricing
      .getAllByRole("link")
      .filter((el) => el.getAttribute("href") === "/auth/login")
    expect(loginLinks.length).toBe(4)
  })

  // ── TRIANGULATE (c): la card aparece después del último plan en el DOM ──────
  it("mounts the Empresa card after the plan grid in DOM order", () => {
    installMatchMediaStub()
    render(<LandingPageFull sections={[]} enterpriseWhatsAppUrl={ENTERPRISE_URL} />)
    const pricing = within(getPricingSection())

    const proHeading = pricing.getByRole("heading", { name: "Pro" })
    const empresaTagline = pricing.getByText(ENTERPRISE_TIER.tagline)

    // DOCUMENT_POSITION_FOLLOWING (4): empresaTagline viene DESPUÉS de "Pro".
    expect(
      proHeading.compareDocumentPosition(empresaTagline) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy()
  })
})
