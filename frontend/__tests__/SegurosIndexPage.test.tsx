/**
 * seguros-perfil-asesor (task 6.1/6.3): /seguros se adapta al CONTEO REAL de
 * entradas visibles (design.md D5), nunca a una constante:
 * - 1 asesor visible y 0 ofertas -> presenta el contenido completo del
 *   asesor en el índice mismo, sin simular una grilla de 3 columnas con 2
 *   huecos.
 * - 2+ asesores visibles -> grilla, cada card enlaza a /seguros/[slug].
 * - Ofertas legacy (`entry_type` 'offer' o ausente) -> siguen renderizando
 *   como hoy, con su link saliente "Más información".
 * - Sin ninguna entrada visible -> estado vacío existente.
 *
 * No toca seguros-click-tracking.test.tsx (red de seguridad, task 6.4).
 *
 * Mockea el servicio (no el cliente Supabase crudo) — mismo criterio que
 * AdvisorProfilePage.test.tsx.
 */

import React from "react"
import { describe, it, expect, vi, beforeEach } from "vitest"
import { render, screen } from "@testing-library/react"
import type { Insurance } from "@/lib/services/insuranceService"

const { getVisibleInsurancesMock, incrementClicksMock, incrementContactClickMock } = vi.hoisted(() => ({
  getVisibleInsurancesMock: vi.fn(),
  incrementClicksMock: vi.fn().mockResolvedValue(undefined),
  incrementContactClickMock: vi.fn().mockResolvedValue(undefined),
}))

vi.mock("@/lib/supabase/client", () => ({
  createClient: () => ({ rpc: vi.fn(), schema: vi.fn() }),
}))

vi.mock("@/lib/services/insuranceService", async () => {
  const actual = await vi.importActual<typeof import("@/lib/services/insuranceService")>(
    "@/lib/services/insuranceService"
  )
  return {
    ...actual,
    insuranceService: {
      ...actual.insuranceService,
      getVisibleInsurances: getVisibleInsurancesMock,
      incrementClicks: incrementClicksMock,
      incrementContactClick: incrementContactClickMock,
    },
  }
})

import SegurosPage from "@/app/(dashboard)/seguros/page"

function makeAdvisor(overrides: Partial<Insurance> = {}): Insurance {
  return {
    id: "advisor-1",
    title: "Julián Dupás — Productor Asesor de Seguros",
    description: "",
    coverage: "",
    price: "",
    contact_url: "https://www.argbroker.com.ar",
    is_visible: true,
    created_at: "2026-09-01T00:00:00.000Z",
    updated_at: "2026-09-01T00:00:00.000Z",
    entry_type: "advisor",
    slug: "julian-dupas",
    advisor_name: "Julián Dupás",
    advisor_role: "Productor Asesor de Seguros",
    license_number: "98506",
    license_authority: null,
    headline: "Un seguro no termina cuando se emite la póliza.",
    bio: "Mi trabajo comienza con el análisis de cada situación particular.",
    photo_url: null,
    contact_phone: "2266 474348",
    contact_whatsapp: "5492266474348",
    contact_email: "julian_dupas@argbroker.com.ar",
    service_lines: [{ title: "Autos y motos", description: "Coberturas adaptadas." }],
    pillars: [{ title: "Comparación de alternativas", body: "No trabajo con una única aseguradora." }],
    coverage_areas: ["Necochea", "Mendoza"],
    disclaimer: "Aliadata no es aseguradora ni intermediaria.",
    contact_clicks: {},
    is_featured: false,
    sort_order: 0,
    ...overrides,
  }
}

function makeOffer(overrides: Partial<Insurance> = {}): Insurance {
  return {
    id: "offer-1",
    title: "Seguro Integral Comercio",
    description: "Cobertura completa para tu local",
    coverage: "Incendio, robo y responsabilidad civil",
    price: "Desde $15.000/mes",
    contact_url: "https://aseguradora.example.com/contacto",
    is_visible: true,
    created_at: "2026-03-01T00:00:00.000Z",
    updated_at: "2026-03-01T00:00:00.000Z",
    ...overrides,
  }
}

beforeEach(() => {
  getVisibleInsurancesMock.mockReset()
  incrementClicksMock.mockReset().mockResolvedValue(undefined)
  incrementContactClickMock.mockReset().mockResolvedValue(undefined)
})

describe("SegurosPage — índice adaptativo al conteo real", () => {
  it("con 1 asesor visible y 0 ofertas presenta el contenido completo del asesor, sin grilla de 3 columnas", async () => {
    getVisibleInsurancesMock.mockResolvedValue([makeAdvisor()])
    render(<SegurosPage />)

    expect(await screen.findByRole("heading", { name: /julián dupás/i })).toBeInTheDocument()
    // "Cómo trabajo" (pilares) sólo lo renderiza el contenido completo del
    // perfil, nunca la card resumen de la grilla -- señal inequívoca de
    // que estamos en modo "un solo asesor", no en modo grilla.
    expect(screen.getByText(/cómo trabajo/i)).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /más información/i })).not.toBeInTheDocument()
  })

  it("con 2 asesores visibles renderiza una card por asesor, cada una enlazando a su slug", async () => {
    getVisibleInsurancesMock.mockResolvedValue([
      makeAdvisor(),
      makeAdvisor({ id: "advisor-2", slug: "otro-asesor", advisor_name: "Otro Asesor" }),
    ])
    render(<SegurosPage />)

    const links = await screen.findAllByRole("link", { name: /ver perfil/i })
    expect(links).toHaveLength(2)
    const hrefs = links.map((l) => l.getAttribute("href")).sort()
    expect(hrefs).toEqual(["/seguros/julian-dupas", "/seguros/otro-asesor"])
    // En modo grilla no se renderiza el contenido completo de ningún asesor
    expect(screen.queryByText(/cómo trabajo/i)).not.toBeInTheDocument()
  })

  it("con 3 asesores visibles renderiza tres cards sin dejar huecos", async () => {
    getVisibleInsurancesMock.mockResolvedValue([
      makeAdvisor({ id: "a1", slug: "a1", advisor_name: "Asesor Uno" }),
      makeAdvisor({ id: "a2", slug: "a2", advisor_name: "Asesor Dos" }),
      makeAdvisor({ id: "a3", slug: "a3", advisor_name: "Asesor Tres" }),
    ])
    render(<SegurosPage />)

    expect(await screen.findAllByRole("link", { name: /ver perfil/i })).toHaveLength(3)
  })

  it("las ofertas legacy siguen renderizando con su link saliente", async () => {
    getVisibleInsurancesMock.mockResolvedValue([makeOffer()])
    render(<SegurosPage />)

    const link = await screen.findByRole("link", { name: /más información/i })
    expect(link).toHaveAttribute("href", "https://aseguradora.example.com/contacto")
    expect(link).toHaveAttribute("target", "_blank")
    expect(link).toHaveAttribute("rel", "noopener noreferrer")
  })

  it("caso mixto: 1 asesor + 1 oferta visibles a la vez -> modo grilla con ambas cards", async () => {
    getVisibleInsurancesMock.mockResolvedValue([makeAdvisor(), makeOffer()])
    render(<SegurosPage />)

    expect(await screen.findByRole("link", { name: /ver perfil/i })).toHaveAttribute(
      "href",
      "/seguros/julian-dupas"
    )
    expect(screen.getByRole("link", { name: /más información/i })).toBeInTheDocument()
    // Modo grilla, no el contenido completo del perfil
    expect(screen.queryByText(/cómo trabajo/i)).not.toBeInTheDocument()
  })

  it("sin ninguna entrada visible conserva el estado vacío existente", async () => {
    getVisibleInsurancesMock.mockResolvedValue([])
    render(<SegurosPage />)

    expect(await screen.findByText(/próximamente seguros para emprendedores/i)).toBeInTheDocument()
  })
})
