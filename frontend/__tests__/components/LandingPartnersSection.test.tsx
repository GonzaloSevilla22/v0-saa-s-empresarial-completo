/**
 * Tests de la sección "Nuestros aliados" de la landing pública (`/`) — PR
 * directo (sin change OPSX, decisión del orquestador con OK del PO
 * 2026-09-01): sección estática de marketing, catálogo tipado en
 * `lib/landing-partners.ts`.
 *
 * Con el catálogo real (1 aliado: Grupo ARG) renderiza una tarjeta
 * centrada, no una grilla con huecos. El componente igual debe soportar
 * 2+ aliados en grilla (catálogo de prueba, prop `partners`) y ocultarse
 * por completo con catálogo vacío — mismo patrón que `TutorialsSection`.
 *
 * Ciclo: RED (el componente no existe) → GREEN → TRIANGULATE (vacío + 2 aliados).
 */

import { describe, it, expect } from "vitest"
import { render, screen } from "@testing-library/react"

import { PartnersSection } from "@/components/landing/PartnersSection"
import type { LandingPartner } from "@/lib/landing-partners"

describe("PartnersSection — sección Nuestros aliados de la landing", () => {
  // ── RED/GREEN: catálogo real (Grupo ARG) ────────────────────────────────
  it("renders the heading and the real partner's logo with its alt text", () => {
    render(<PartnersSection />)

    expect(screen.getByRole("heading", { name: /nuestros aliados/i })).toBeInTheDocument()

    const logo = screen.getByAltText("Grupo ARG — Brokers de Seguros")
    expect(logo).toHaveAttribute("src", "/partners/grupo-arg.png")
    expect(screen.getByText("Grupo ARG · Brokers de Seguros")).toBeInTheDocument()
  })

  it("exposes the section landmark with id and aria-label for anchor navigation", () => {
    const { container } = render(<PartnersSection />)

    const section = container.querySelector("section#aliados")
    expect(section).not.toBeNull()
    expect(section).toHaveAttribute("aria-label")
  })

  // ── TRIANGULATE: catálogo vacío ⇒ la sección no se renderiza ────────────
  it("renders nothing when the partner catalog is empty", () => {
    const { container } = render(<PartnersSection partners={[]} />)

    expect(container).toBeEmptyDOMElement()
  })

  // ── TRIANGULATE: 2+ aliados ⇒ ambos se renderizan (grilla, no tarjeta única) ─
  it("renders every partner when the catalog has two or more entries", () => {
    const twoPartners: LandingPartner[] = [
      {
        name: "Aliado Uno",
        logoSrc: "/partners/aliado-uno.png",
        logoAlt: "Logo de Aliado Uno",
        blurb: "Descripción del primer aliado de prueba.",
      },
      {
        name: "Aliado Dos",
        logoSrc: "/partners/aliado-dos.png",
        logoAlt: "Logo de Aliado Dos",
        blurb: "Descripción del segundo aliado de prueba.",
      },
    ]

    render(<PartnersSection partners={twoPartners} />)

    expect(screen.getByText("Aliado Uno")).toBeInTheDocument()
    expect(screen.getByText("Aliado Dos")).toBeInTheDocument()
    expect(screen.getByAltText("Logo de Aliado Uno")).toHaveAttribute("src", "/partners/aliado-uno.png")
    expect(screen.getByAltText("Logo de Aliado Dos")).toHaveAttribute("src", "/partners/aliado-dos.png")
  })
})
