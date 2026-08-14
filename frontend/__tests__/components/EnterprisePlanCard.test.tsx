/**
 * Tests de `components/shared/EnterprisePlanCard.tsx` — card compartida del
 * tier Empresa (change `plan-empresa-contacto`, design.md D2/D3/D7).
 *
 * Un solo componente, dos variantes visuales (`landing` | `app`). No lee env
 * vars ni arma URLs: recibe `whatsappUrl` ya armada por el server (D2), así
 * sirve tanto en el árbol de cliente de la landing como en el de servidor de
 * `/planes`.
 *
 * Ciclo: RED (el componente no existe) → GREEN → TRIANGULATE.
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"
import { EnterprisePlanCard } from "@/components/shared/EnterprisePlanCard"
import { ENTERPRISE_TIER } from "@/lib/enterprise-tier"

const WA_URL = "https://wa.me/5492617635174?text=Hola%20ALIADATA"

describe("EnterprisePlanCard", () => {
  // ── RED/GREEN: contenido básico con variant="app" ──────────────────────────
  it("renders name, tagline, the 4 bullets and a link to whatsappUrl", () => {
    render(<EnterprisePlanCard whatsappUrl={WA_URL} variant="app" />)

    expect(screen.getByText(ENTERPRISE_TIER.name)).toBeInTheDocument()
    expect(screen.getByText(ENTERPRISE_TIER.tagline)).toBeInTheDocument()
    for (const feature of ENTERPRISE_TIER.features) {
      expect(screen.getByText(feature)).toBeInTheDocument()
    }

    const link = screen.getByRole("link", { name: ENTERPRISE_TIER.ctaAccessibleLabel })
    expect(link).toHaveAttribute("href", WA_URL)
  })

  // ── TRIANGULATE (a): enlace saliente protegido ──────────────────────────────
  it("declares target=_blank and rel with noopener and noreferrer", () => {
    render(<EnterprisePlanCard whatsappUrl={WA_URL} variant="app" />)

    const link = screen.getByRole("link", { name: ENTERPRISE_TIER.ctaAccessibleLabel })
    expect(link).toHaveAttribute("target", "_blank")
    const rel = link.getAttribute("rel") ?? ""
    expect(rel).toContain("noopener")
    expect(rel).toContain("noreferrer")
  })

  // ── TRIANGULATE (b): nombre accesible menciona WhatsApp, el plan y la pestaña
  it("the accessible name mentions WhatsApp, the plan Empresa and the new tab", () => {
    render(<EnterprisePlanCard whatsappUrl={WA_URL} variant="app" />)

    const link = screen.getByRole("link", { name: /whatsapp/i })
    const name = link.getAttribute("aria-label") ?? link.textContent ?? ""
    expect(name.toLowerCase()).toContain("whatsapp")
    expect(name.toLowerCase()).toContain("empresa")
    expect(name.toLowerCase()).toMatch(/pestaña nueva|nueva pestaña/)
  })

  // ── TRIANGULATE (c): el ícono es decorativo ────────────────────────────────
  it("hides the icon from assistive tech", () => {
    const { container } = render(<EnterprisePlanCard whatsappUrl={WA_URL} variant="app" />)

    const hiddenIcon = container.querySelector('[aria-hidden="true"]')
    expect(hiddenIcon).not.toBeNull()
  })

  // ── TRIANGULATE (d): landing y app → mismo texto/href, distintas clases ────
  it("variant='landing' and variant='app' share text and href but differ in classes", () => {
    const { container: appContainer } = render(
      <EnterprisePlanCard whatsappUrl={WA_URL} variant="app" />,
    )
    const appCard = appContainer.firstElementChild as HTMLElement

    const { container: landingContainer } = render(
      <EnterprisePlanCard whatsappUrl={WA_URL} variant="landing" />,
    )
    const landingCard = landingContainer.firstElementChild as HTMLElement

    expect(appCard.textContent).toBe(landingCard.textContent)
    expect(appCard.className).not.toBe(landingCard.className)

    const appLink = appContainer.querySelector("a")
    const landingLink = landingContainer.querySelector("a")
    expect(appLink).toHaveAttribute("href", WA_URL)
    expect(landingLink).toHaveAttribute("href", WA_URL)
  })

  // ── TRIANGULATE (e): nunca se muestra un importe ni un período ─────────────
  it("never renders a monthly amount or a billing period", () => {
    render(<EnterprisePlanCard whatsappUrl={WA_URL} variant="app" />)

    expect(screen.queryByText(/\$\s?\d/)).toBeNull()
    expect(screen.queryByText(/\/mes/i)).toBeNull()
  })
})
